import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/username_scope.dart';
import '../models/device.dart';
import '../models/network.dart';
import 'settings_service.dart';
import 'tls_service.dart';

/// 局域网发现。
///
/// 严格对齐 LocalSend Protocol v2.2 的双向发现：
/// 1. 组播 announce：向 224.0.0.167:53317 发一条 JSON 广播；
/// 2. 单播 register 回应：收到 announce 后，用 HTTP POST /register 单播回给对方；
/// 3. 兜底扫描：逐个私网地址 POST /register（组播被 AP 隔离时用）。
///
/// 第 2 步是关键——官方 LocalSend 收到 announce 后**只**用单播 HTTP 回应，
/// 如果只在组播层解析报文，就会永远看不到官方客户端。
class DiscoveryService {
  DiscoveryService({
    required this.settings,
    required this.onDevice,
    required this.onError,
    this.secure = false,
  });

  final WispSettings settings;
  final void Function(WispDevice device) onDevice;
  final void Function(String message) onError;

  /// 接收端实际是否启用了 TLS。announce 里的 protocol 字段必须与之一致，
  /// 否则对方会按 https 来连，而我们在 http 上监听，直接对不上。
  bool secure;

  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  Timer? _scanTimer;
  final Map<String, DateTime> _seen = <String, DateTime>{};

  /// 已经就「证书与声明不符」告警过的 IP。
  ///
  /// 扫描是每 [WispSettings.scanIntervalSeconds] 秒一轮，同一台设备每轮都会
  /// 再撞一次；不去重就是隔几秒刷一条同样的横幅，真正的告警反而被淹没。
  /// 上限是子网里的地址数，不会无限增长。
  final Set<String> _mismatchWarned = <String>{};
  String? _selfIp;
  bool _scanning = false;
  bool _disposed = false;
  bool _multicastOk = false;
  bool _recovering = false;
  int _sendFailures = 0;

  /// 最近一次收到别的设备 announce 的时间。设置页用它显示"发现是否真的在工作"。
  DateTime? _lastPeerAt;
  DateTime? get lastPeerAt => _lastPeerAt;

  /// 最近一次成功发出 announce 的时间。
  DateTime? _lastAnnounceAt;
  DateTime? get lastAnnounceAt => _lastAnnounceAt;

  bool get isRunning => _socket != null || _scanning;

  /// 组播是否可用（不可用时界面要提示用户改用扫描）。
  bool get multicastAvailable => _multicastOk;

  Future<void> start() async {
    if (isRunning) return;
    // 每轮启动重新允许告警一次：换网络之后同一地址可能是另一台设备。
    _mismatchWarned.clear();
    _selfIp = await resolveLocalIp(settings.networkInterface);
    if (_selfIp == null) {
      onError('没有找到可用的局域网地址，请检查网络连接');
    }

    // Android 为省电默认在内核层丢组播包，必须持有 MulticastLock 才能收到
    // announce。锁由 MainActivity 通过方法通道持有，进程结束自动释放。
    if (Platform.isAndroid) {
      try {
        await _androidChannel
            .invokeMethod<bool>('acquireMulticastLock')
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        // 通道不可用（如宿主侧未实现）不打断发现流程，扫描模式仍可用。
      }
    }

    if (settings.discoveryMode.multicastEnabled) {
      await _startMulticast();
    }
    if (settings.discoveryMode.scanEnabled) {
      unawaited(scanSubnet());
      _scheduleScan();
    }
  }

  Future<void> _startMulticast() async {
    if (_socket != null) return;
    try {
      // 关键：必须绑定 anyIPv4。
      //
      // 之前绑的是本机单播地址（192.168.x.x），这在 Windows 上是个陷阱——
      // 组播报文的目的地址是 224.0.0.167，而 socket 只认自己绑定的那个单播地址，
      // 能不能收到完全取决于系统把 IP_ADD_MEMBERSHIP 挂到了哪块网卡上，
      // 结果是"有时能发现、有时一台都看不到"。
      // 绑 anyIPv4 才是各平台一致、官方客户端也在用的做法。
      final RawDatagramSocket socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        // 组播端口是协议固定的 53317，不跟随自定义 HTTP 端口。
        WispProtocol.multicastPort,
        reuseAddress: true,
      );
      // 只在本子网内传播，跨网段没有意义。
      socket.multicastHops = 1;
      // 必须开启回环：同一台机器上同时跑官方 LocalSend 做对照测试时，
      // 关掉回环会让两个进程彻底看不见彼此（IP_MULTICAST_LOOP 是发送端选项，
      // 关掉后连本机其它进程都收不到）。自己发的包靠 fingerprint 过滤。
      socket.multicastLoopback = true;

      // 把组播出口钉到连局域网的那块网卡上。
      //
      // 这一步是"Wisp 能看到对方、对方搜不到 Wisp"的关键：装了 VPN / Hyper-V /
      // WSL 之后系统默认路由往往不走物理网卡，announce 就从错误的网卡发出去了，
      // 局域网里的官方客户端一个包都收不到。Dart 的 multicastInterface 至今没实现
      // （调用直接抛 UnimplementedError），只能走底层 socket 选项。
      final String? selfIp = _selfIp;
      if (selfIp != null) _pinMulticastInterface(socket, selfIp);

      try {
        socket.joinMulticast(InternetAddress(WispProtocol.multicastAddress));
        _multicastOk = true;
      } on SocketException {
        // 少数定制系统拒绝加入组播，此时只剩扫描兜底。
        _multicastOk = false;
        onError('当前网络不支持组播发现，已切换为扫描模式');
      }

      socket.listen(
        _onSocketEvent,
        onError: (Object error) {
          onError('发现服务异常：$error');
          _recoverSocket();
        },
        onDone: _recoverSocket,
      );
      _socket = socket;
      _sendFailures = 0;

      // 启动瞬间连发几次：UDP 没有重传，第一包正好撞上对方网卡休眠/路由表
      // 还没就绪就永远补不回来。之后转入 3 秒一次的常态心跳。
      _announce();
      for (final int delay in <int>[250, 700, 1500, 3000]) {
        Timer(Duration(milliseconds: delay), _announce);
      }
      _announceTimer = Timer.periodic(const Duration(seconds: 3), (_) => _announce());
      _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) => _prune());
    } on SocketException catch (e) {
      _multicastOk = false;
      onError('无法占用 ${WispProtocol.multicastPort} 端口：${e.osError?.message ?? e.message}');
    }
  }

  /// Android 侧方法通道（组播锁），仅 Android 上会真正用到。
  static const MethodChannel _androidChannel = MethodChannel('wisp/android');

  /// 把组播出口网卡钉到 [ip] 所在的那块网卡。
  ///
  /// `IP_MULTICAST_IF` 的平台常量并不统一：Windows / macOS / iOS 是 9，
  /// Linux 与 Android（同为 Linux 内核）是 32；值就是 4 字节的 in_addr（网络字节序）。
  /// 任何一步不被支持就安静退回系统默认路由——那总比把发送整个搞坏强。
  void _pinMulticastInterface(RawDatagramSocket socket, String ip) {
    const int ipProtoIp = 0;
    final int multicastIf = (Platform.isLinux || Platform.isAndroid) ? 32 : 9;
    try {
      socket.setRawOption(RawSocketOption(
        ipProtoIp,
        multicastIf,
        Uint8List.fromList(InternetAddress(ip).rawAddress),
      ));
    } catch (_) {
      // 平台不支持该选项，保持系统默认。
    }
  }

  /// 重建已经不可用的组播 socket。
  ///
  /// Windows 上 UDP 的 ICMP 错误（对端端口不可达之类）会让 socket 进入错误态，
  /// 之后既收不到也发不出。这里关掉重开，比让发现功能永久静默要好。
  void _recoverSocket() {
    if (_disposed || _recovering) return;
    _recovering = true;
    _announceTimer?.cancel();
    _announceTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    try {
      _socket?.close();
    } catch (_) {
      // 已经关掉了也无所谓。
    }
    _socket = null;
    _multicastOk = false;
    // 等两秒再重建：网络抖动时别疯狂重连。
    Timer(const Duration(seconds: 2), () {
      _recovering = false;
      if (_disposed) return;
      unawaited(_startMulticast());
    });
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final RawDatagramSocket? socket = _socket;
    if (socket == null) return;
    // 一次 read 事件可能对应接收队列里的**多个**数据报。
    // 只取一个就走，同刻到达的其它 announce 会被直接丢掉——
    // 这正是"有时能发现、有时发现不了"的另一半原因。必须排空队列。
    while (true) {
      final Datagram? datagram;
      try {
        datagram = socket.receive();
      } on SocketException {
        // Windows 上 UDP 的 ICMP 错误（上一次 send 打到不可达地址之类）
        // 会在下一次 receive 时以异常浮出来。吞掉继续，绝不能让监听就此中断。
        break;
      }
      if (datagram == null) break;
      try {
        _handleDatagram(datagram);
      } catch (_) {
        // 单条报文有问题不影响后续报文。
      }
    }
  }

  void _handleDatagram(Datagram datagram) {
    if (datagram.data.length > WispProtocol.maxDatagramBytes) return;

    final String ip = datagram.address.address;
    if (ip == InternetAddress.loopbackIPv4.address) return;
    // 这里**不**按「本机 IP」过滤：同一台机器上完全可能同时跑着
    // 官方 LocalSend（或者第二个 Wisp）做对照测试，按 IP 过滤会把它们
    // 一起挡在门外。自己的包靠下面的 fingerprint 比对排掉就够了。

    final String raw = utf8.decode(datagram.data, allowMalformed: true);
    final Map<String, dynamic>? payload = _decode(raw);
    if (payload == null) return;

    final WispDevice device = WispDevice.fromJson(payload, ip: ip);
    if (device.fingerprint == settings.fingerprint) return;
    // 用户名不同就当没听见：既不记进列表，也**不**回 register。
    // 回了等于把自己的信息主动交出去——对方本来只能靠扫描才知道我们在。
    if (!_inScope(device)) return;

    _lastPeerAt = DateTime.now();
    _remember(device);

    // 对方在问"附近有谁"，回一条单播 HTTP register，让对方也能发现我们。
    if (payload['announce'] as bool? ?? false) {
      unawaited(_replyTo(device));
    }
  }

  Map<String, dynamic>? _decode(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded.containsKey('alias')) return decoded;
    } on FormatException {
      return null;
    }
    return null;
  }

  void _remember(WispDevice device) {
    _seen[device.key] = DateTime.now();
    onDevice(device);
  }

  /// 对方 announce 过来了，用单播 HTTP register 回应自己。
  ///
  /// 这一步是双向发现的关键：官方客户端收到后才把我们加进它的列表。
  Future<void> _replyTo(WispDevice device) async {
    final WispDevice? self = await _registerTo(device.ip, device.port, device.https);
    if (self != null && self.fingerprint != settings.fingerprint) {
      _remember(self);
    }
  }

  Map<String, dynamic> _selfPayload({bool announce = true}) => <String, dynamic>{
        'alias': settings.alias,
        'version': WispProtocol.version,
        'deviceModel': platformLabel(),
        'deviceType': settings.deviceKind.name,
        'fingerprint': settings.fingerprint,
        'port': settings.port,
        // 必须反映实际协议，否则对方会按错的方式连回来。
        'protocol': secure ? 'https' : 'http',
        'download': false,
        'announce': announce,
        if (settings.hasUsername) 'username': settings.username.trim(),
      };

  void _announce() {
    if (!settings.visible) return;
    final RawDatagramSocket? socket = _socket;
    if (socket == null) return;
    try {
      socket.send(
        utf8.encode(jsonEncode(_selfPayload())),
        InternetAddress(WispProtocol.multicastAddress),
        WispProtocol.multicastPort,
      );
      _lastAnnounceAt = DateTime.now();
      _sendFailures = 0;
    } on SocketException {
      // 之前这里还会补发一条 255.255.255.255 的子网广播兜底，已经去掉：
      // Windows 上打到不可达广播地址会积累 ICMP 错误，反而把组播 socket
      // 拖进"收不到也发不出"的状态，得不偿失。
      _sendFailures++;
      if (_sendFailures >= 3) {
        _sendFailures = 0;
        _recoverSocket();
      }
    }
  }

  void _prune() {
    final DateTime now = DateTime.now();
    _seen.removeWhere((String key, DateTime seen) => now.difference(seen).inSeconds > 15);
  }

  void _scheduleScan() {
    _scanTimer?.cancel();
    final int interval = settings.scanIntervalSeconds;
    if (interval <= 0) return;
    _scanTimer = Timer.periodic(Duration(seconds: interval), (_) => scanSubnet());
  }

  /// 逐个私网地址探测。并发 32 路、单点 1.2s 超时，一个 /24 约 10 秒扫完。
  ///
  /// 超时不能压太短：官方客户端桌面版走的是 HTTPS 自签证书，
  /// 握手本身就要几百毫秒，700ms 的旧值会把慢一点的设备整个漏掉。
  Future<void> scanSubnet() async {
    if (_scanning || !settings.discoveryMode.scanEnabled) return;
    _scanning = true;
    try {
      _selfIp ??= await resolveLocalIp(settings.networkInterface);
      final String? ip = _selfIp;
      if (ip == null) return;
      final String prefix = ip.substring(0, ip.lastIndexOf('.'));

      final HttpClient client = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 1200)
        ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;

      const int batch = 32;
      for (int i = 1; i <= 254; i += batch) {
        if (_disposed) break;
        final List<int> slice = <int>[
          for (int host = i; host < i + batch && host <= 254; host++) host,
        ];
        await Future.wait(slice.map((int host) => _probe(client, '$prefix.$host')));
      }
      client.close(force: true);
    } finally {
      _scanning = false;
    }
  }

  Future<void> _probe(HttpClient client, String ip) async {
    if (ip == _selfIp || _disposed) return;
    // 同时探当前端口与默认 53317：用户把本机端口改成别的（为了和官方客户端
    // 同机共存）之后，对端多数还守在 53317 上，只探 settings.port 会让
    // 扫描兜底形同虚设。
    for (final int port in _probePorts) {
      for (final String scheme in <String>['https', 'http']) {
        try {
          final Uri uri = Uri.parse('$scheme://$ip:$port${WispProtocol.registerPath}');
          final HttpClientRequest request = await client.postUrl(uri);
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(_selfPayload(announce: false)));
          final HttpClientResponse response =
              await request.close().timeout(const Duration(milliseconds: 1500));
          if (response.statusCode != 200) {
            // 必须把响应体读完，否则连接会挂在池子里泄漏。
            await response.drain<void>();
            continue;
          }
          final String body = await response.transform(utf8.decoder).join();
          final Map<String, dynamic>? payload = _decode(body);
          if (payload == null) return;
          if (!_certMatchesClaim(response, payload)) {
            _reportMismatch(ip);
            return;
          }
          final WispDevice device = WispDevice.fromJson(payload, ip: ip);
          if (device.fingerprint == settings.fingerprint) return;
          if (!_inScope(device)) return;
          _remember(device);
          return;
        } catch (_) {
          // 绝大多数 IP 上并没有设备，探测失败属于常态，静默跳过。
        }
      }
    }
  }

  /// 对端出示的证书必须与它自己声明的指纹一致。
  ///
  /// 自签证书没有 CA 可验，能做的第一步就是这个：想冒充别人，光换一张
  /// 证书不够，报文里的 `fingerprint` 也得跟着换，而那个字段正是我们
  /// 回连时用来校验的。返回 true 也包括「对端没报指纹 / 走明文 / 报的不是
  /// 证书指纹形状」这种无法判定的情况——那是协议兼容的代价，不在这里拦。
  bool _certMatchesClaim(HttpClientResponse response, Map<String, dynamic> payload) {
    final bool? ok = WispTls.certMatchesClaim(
      response.certificate,
      payload['fingerprint'] as String?,
    );
    return ok ?? true;
  }

  /// 这台设备是否与本机在同一个用户名范围内（规则见 core/username_scope.dart）。
  bool _inScope(WispDevice device) =>
      sameUsernameScope(settings.username, device.username);

  /// 同一台设备只告警一次，避免每轮扫描刷一条同样的横幅。
  void _reportMismatch(String ip) {
    if (!_mismatchWarned.add(ip)) return;
    onError('$ip 出示的证书与它声明的指纹不一致，已忽略');
  }

  /// 只对单个地址跑一次探测（不走组播、不扫全段）。
  ///
  /// 给测试用：证书比对的误报在真实网络里表现为"设备凭空消失 + 横幅刷屏"，
  /// 必须能在不接真实局域网的情况下钉死。
  @visibleForTesting
  Future<void> probeAddress(String ip) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 1200)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    try {
      await _probe(client, ip);
    } finally {
      client.close(force: true);
    }
  }

  /// 扫描要探的端口列表：当前端口优先，再补默认端口（去重）。
  List<int> get _probePorts {
    final int own = settings.port;
    return <int>[
      own,
      if (own != WispProtocol.defaultPort) WispProtocol.defaultPort,
    ];
  }

  /// 主动向某个 IP 打招呼（手动连接 / 收藏设备时用）。
  Future<WispDevice?> _registerTo(String ip, int port, bool https) async {
    // 先按对方声明的协议试，不通再换另一种。
    // 对方 announce 里的 protocol 偶尔和实际监听对不上（典型是证书生成失败
    // 后退回了 http），只认一种会白白漏掉这台设备。
    final WispDevice? first = await _postRegister(ip, port, https);
    if (first != null) return first;
    return _postRegister(ip, port, !https);
  }

  Future<WispDevice?> _postRegister(String ip, int port, bool https) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 1200)
      ..badCertificateCallback = (X509Certificate cert, String host, int p) => true;
    try {
      final Uri uri = Uri.parse('${https ? 'https' : 'http'}://$ip:$port${WispProtocol.registerPath}');
      final HttpClientRequest request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(_selfPayload(announce: false)));
      final HttpClientResponse response =
          await request.close().timeout(const Duration(milliseconds: 1500));
      if (response.statusCode != 200) return null;
      final String body = await response.transform(utf8.decoder).join();
      final Map<String, dynamic>? payload = _decode(body);
      if (payload == null) return null;
      if (!_certMatchesClaim(response, payload)) {
        _reportMismatch(ip);
        return null;
      }
      final WispDevice device = WispDevice.fromJson(payload, ip: ip);
      return _inScope(device) ? device : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static String platformLabel() {
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    return 'Unknown';
  }

  /// 取本机私网 IPv4。指定了网卡就用那块，否则用系统默认的那块。
  static Future<String?> resolveLocalIp(String? interfaceId) async {
    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final List<NetworkInterfaceInfo> all = <NetworkInterfaceInfo>[];
      for (final NetworkInterface interface in interfaces) {
        for (final InternetAddress address in interface.addresses) {
          if (address.isLoopback) continue;
          final String ip = address.address;
          if (!ip.startsWith('192.168.') &&
              !ip.startsWith('10.') &&
              !ip.startsWith('172.')) {
            continue;
          }
          all.add(
            NetworkInterfaceInfo(
              name: interface.name,
              address: ip,
              isVirtual: NetworkInterfaceInfo.looksVirtual(interface.name),
            ),
          );
        }
      }
      if (all.isEmpty) return null;

      if (interfaceId != null && interfaceId.isNotEmpty) {
        for (final NetworkInterfaceInfo info in all) {
          if (info.id == interfaceId) return info.address;
        }
      }

      final List<NetworkInterfaceInfo> sorted = List<NetworkInterfaceInfo>.from(all)
        ..sort((NetworkInterfaceInfo a, NetworkInterfaceInfo b) {
          if (a.isVirtual != b.isVirtual) return a.isVirtual ? 1 : -1;
          return a.address.compareTo(b.address);
        });
      return sorted.first.address;
    } on SocketException {
      return null;
    }
  }

  /// 取本机私网 IPv4，用于扫描网段和界面展示。
  static Future<String?> localIpv4() => resolveLocalIp(null);

  Future<void> dispose() async {
    _disposed = true;
    _announceTimer?.cancel();
    _pruneTimer?.cancel();
    _scanTimer?.cancel();
    _socket?.close();
    _socket = null;
    if (Platform.isAndroid) {
      try {
        await _androidChannel.invokeMethod<void>('releaseMulticastLock');
      } catch (_) {
        // 进程退出时锁会被系统回收，这里失败无须处理。
      }
    }
  }
}
