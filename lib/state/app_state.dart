import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../core/utils/format.dart';
import '../core/utils/pickers.dart';
import '../models/device.dart';
import '../models/network.dart';
import '../models/transfer.dart';
import '../services/desktop_service.dart';
import '../services/discovery_service.dart';
import '../services/history_service.dart';
import '../services/notification_router.dart';
import '../services/receiver_service.dart';
import '../services/sender_service.dart';
import '../services/settings_service.dart';
import '../services/tls_service.dart';
import '../core/release_notes.dart';
import '../services/update_service.dart';

/// 全局状态中枢。
///
/// 界面只读这里的字段、只调这里的方法；
/// 网络层通过回调把事件推回来，避免 UI 直接摸 socket。
class AppState extends ChangeNotifier {
  AppState();

  final SettingsService _settingsService = SettingsService();
  final HistoryService _historyService = HistoryService();

  WispSettings settings = WispSettings.defaults();
  bool ready = false;
  String? localIp;
  String? banner;

  /// 内置自签证书的 SHA-256 指纹（形如 F0:08:…），证书缺失时为 null。
  String? certFingerprint;

  final List<WispDevice> devices = <WispDevice>[];
  final List<TransferFile> draft = <TransferFile>[];
  final List<TransferSession> sessions = <TransferSession>[];
  final List<TransferRecord> history = <TransferRecord>[];

  /// 每准备好一批待发内容就 +1（拖拽进来、历史里重发），外壳据此切到发送页。
  /// 只在变化时翻页，避免每次 notify 都把用户拽回这一页。
  int composeTick = 0;

  /// 发送页要自动选中的设备 IP：历史里"再次发送"时对端仍在线就顺手选上。
  /// SendPage 用掉后置回 null。
  String? preferredPeerIp;

  IncomingRequest? incoming;
  TransferSession? activeSession;

  DiscoveryService? _discovery;
  ReceiverService? _receiver;
  final Set<String> _finished = <String>{};
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// 设备最后一次被看到后多久算离线。组播 announce 是 3~5 秒一次，
  /// 给到 60 秒是留足丢包与休眠唤醒的余量。
  static const Duration _deviceTtl = Duration(seconds: 60);

  /// 定期巡检：清理离线设备 + 检测本机地址变化。
  Timer? _sweepTimer;
  String? _watchedIp;
  bool _restartingNetwork = false;

  /// 自动检查更新的兜底轮询：应用长期不重启时也能按频率到点。
  Timer? _updateTimer;

  /// 自动检查发现的新版本信息。null = 没查到新版本（或还没查/已关闭）。
  WispUpdateInfo? pendingUpdate;

  /// 防抖：同一时刻只允许一次检查在飞（启动与轮询可能撞车）。
  bool _updateCheckInFlight = false;

  // 桌面通知状态机：
  // _bubbleShown/_bubbleAccepted —— 悬浮球气泡流程是否活着、用户是否已确认。
  // _toastShown —— 右下角通知卡片流程是否活着（询问/进度都在这张卡上）。
  // _progressSurfaceShown —— 确认后进度面板（气泡或卡片）是否已创建。
  // _desktopSuppressed —— 用户打开了主窗口：桌面提醒全部退场并停止推进。
  // _useBallForFlow —— 本次流程走悬浮球气泡（true）还是通知卡片（false）。
  bool _bubbleShown = false;
  bool _bubbleAccepted = false;
  bool _toastShown = false;
  bool _progressSurfaceShown = false;
  bool _desktopSuppressed = false;
  bool _useBallForFlow = false;
  DateTime _lastBubbleUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  /// 可用的网卡列表，供设置页选择。
  List<NetworkInterfaceInfo> interfaces = <NetworkInterfaceInfo>[];

  bool get isScanning => _discovery?.isRunning ?? false;
  bool get receiverRunning => _receiver?.isRunning ?? false;
  bool get encrypted => _receiver?.isSecure ?? false;

  /// 组播是否可用。不可用时界面要提示改用扫描模式。
  bool get multicastAvailable => _discovery?.multicastAvailable ?? false;

  /// 最近一次收到别的设备广播的时间（诊断用：为空说明一个包都没进来）。
  DateTime? get discoveryLastPeerAt => _discovery?.lastPeerAt;

  /// 最近一次成功发出广播的时间（诊断用：为空说明组播发不出去）。
  DateTime? get discoveryLastAnnounceAt => _discovery?.lastAnnounceAt;

  /// 因为用户名不匹配而被隐藏掉的设备数量。
  int get hiddenByUsername => _filteredKeys.length;

  final Set<String> _filteredKeys = <String>{};

  int get draftBytes => draft.fold(0, (int sum, TransferFile f) => sum + f.size);

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    settings = await _settingsService.load();
    history
      ..clear()
      ..addAll(await _historyService.load());
    interfaces = await NetworkInterfaceInfo.list();
    localIp = await DiscoveryService.resolveLocalIp(settings.networkInterface);
    // 证书指纹：设置页要显示，两端对指纹时用。
    certFingerprint = await WispTls.fingerprint();
    // 托盘开关保存在本地设置里，启动时同步给原生层。
    await DesktopService.setMinimizeToTray(settings.minimizeToTray);
    // 原生层事件（点悬浮球、点气泡按钮、点通知、气泡超时）统一从这里回来。
    DesktopService.setEventHandler(_onDesktopEvent);
    await DesktopService.setFloatingBall(
      settings.floatingBall,
      hoverDelayMs: settings.ballShowDelayMs,
      savedPosX: settings.ballPosX,
      savedPosY: settings.ballPosY,
      savedSnapped: settings.ballSnapped,
      savedEdge: settings.ballEdge,
    );
    await _startNetwork();
    _watchedIp = localIp;
    _startSweep();
    // 服务守护的真实状态以服务管理器为准，启动时回查一次。
    _serviceStatus = await DesktopService.serviceStatus();
    ready = true;
    notifyListeners();
    // 版本检查放最后台跑，不挡启动。
    unawaited(_autoUpdateCheck());
    _startUpdatePolling();
  }

  Future<void> _startNetwork() async {
    await _discovery?.dispose();
    await _receiver?.dispose();

    final ReceiverService receiver = ReceiverService(
      settings: settings,
      onIncoming: (IncomingRequest request) {
        handleIncomingRequest(request);
        return request.decision;
      },
      onProgress: (TransferSession session) {
        _updateDesktopProgress(session);
        _throttleNotify();
      },
      onFinished: (TransferSession session) {
        _finishSession(session);
        _notifyDesktopFinished(session);
        notifyListeners();
      },
      onLog: (String message) => _log(message),
      // 对方主动握手时也要进设备列表——这是发现官方客户端的唯一途径。
      onRegistered: _upsertDevice,
    );

    final DiscoveryService discovery = DiscoveryService(
      settings: settings,
      onDevice: _upsertDevice,
      onError: _log,
      secure: receiver.isSecure,
    );

    _receiver = receiver;
    _discovery = discovery;

    await receiver.start();
    // 接收端可能因为缺证书从 https 退回 http，announce 的 protocol 必须跟着变。
    discovery.secure = receiver.isSecure;
    await discovery.start();
    notifyListeners();
  }

  /// 定期巡检：清掉久未刷新的设备，并在本机地址变化后重建发现链路。
  void _startSweep() {
    _sweepTimer?.cancel();
    _sweepTimer = Timer.periodic(const Duration(seconds: 15), (_) => _sweep());
  }

  Future<void> _sweep() async {
    // 1) 离线设备不能一直挂在列表里——那会让人以为"发现功能坏了"。
    final DateTime now = DateTime.now();
    final List<String> expired = <String>[];
    devices.removeWhere((WispDevice d) {
      final DateTime? seen = d.lastSeen;
      if (seen == null) return false;
      final bool stale = now.difference(seen) > _deviceTtl;
      if (stale) expired.add(d.key);
      return stale;
    });
    if (expired.isNotEmpty) {
      _filteredKeys.removeAll(expired);
      notifyListeners();
    }

    // 2) 换 Wi-Fi、插拔网线、VPN 启停都会让本机地址变化。
    //    组播 socket 还绑在旧地址上就永远发现不到人，必须自动重建链路。
    if (!ready || _restartingNetwork) return;
    final String? current = await DiscoveryService.resolveLocalIp(settings.networkInterface);
    if (current == null || current == _watchedIp) return;
    _watchedIp = current;
    localIp = current;
    _restartingNetwork = true;
    try {
      await _startNetwork();
      notifyListeners();
    } finally {
      _restartingNetwork = false;
    }
  }

  /// 加入或更新一台设备。设置了识别用户名时，只保留同名用户的设备。
  void _upsertDevice(WispDevice device) {
    if (device.fingerprint == settings.fingerprint) return;

    if (settings.hasUsername && device.username.trim() != settings.username.trim()) {
      // 用户名对不上：这类设备不该出现在列表里。
      _filteredKeys.add(device.key);
      notifyListeners();
      return;
    }
    _filteredKeys.remove(device.key);

    final int index = devices.indexWhere((WispDevice d) => d.key == device.key);
    if (index >= 0) {
      devices[index] = device;
    } else {
      devices.add(device);
    }
    devices.sort((WispDevice a, WispDevice b) => a.alias.compareTo(b.alias));
    notifyListeners();
  }

  /// 供测试直接喂进一台设备，走和真实发现完全一样的过滤逻辑。
  @visibleForTesting
  void acceptDeviceForTest(WispDevice device) => _upsertDevice(device);

  /// 传输中的高频回调不需要每字节刷新，100ms 一次足够顺滑。
  void _throttleNotify() {    final DateTime now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds < 100) return;
    _lastNotify = now;
    notifyListeners();
  }

  void _log(String message) {
    banner = message;
    notifyListeners();
  }

  void clearBanner() {
    if (banner == null) return;
    banner = null;
    notifyListeners();
  }

  /// 手动重扫网段（组播被墙时的主要救命手段）。
  Future<void> rescan() async {
    interfaces = await NetworkInterfaceInfo.list();
    await _discovery?.scanSubnet();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 更新检查
  // ---------------------------------------------------------------------------

  /// 应用长时间挂着不重启时，每 30 分钟看一眼"到点了吗"；
  /// 真正的网络请求由 [_autoUpdateCheck] 按频率闸门放行，轮询本身零成本。
  void _startUpdatePolling() {
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => unawaited(_autoUpdateCheck()),
    );
  }

  /// 按用户设置的频率自动检查更新。
  ///
  /// * 频率关闭或没到点：直接返回，不发任何网络请求；
  /// * 检查完成就记时间（失败也算，避免断网时反复请求）；
  /// * 查到更新：存进 [pendingUpdate]，弹一条不打扰的 SnackBar；
  /// * 请求期间用户改了频率设置：丢弃结果，等下一轮。
  Future<void> _autoUpdateCheck() async {
    if (_updateCheckInFlight) return;
    final int hours = settings.updateCheckHours;
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (!WispUpdateCadence.isDue(hours, settings.lastUpdateCheckMs, now)) return;

    _updateCheckInFlight = true;
    try {
      final WispUpdateInfo? info = await WispUpdateService.check();
      // 检查期间频率设置被改动了：这次结果不再可信，也不落时间戳。
      if (settings.updateCheckHours != hours) return;
      await updateSettings(settings.copyWith(lastUpdateCheckMs: now));
      if (info != null &&
          WispUpdateService.isNewer(info.latestVersion, WispReleaseNotes.currentVersion)) {
        pendingUpdate = info;
        banner = '发现新版本 v${info.latestVersion}，到 设置 → 关于 查看更新内容与下载';
        notifyListeners();
      }
    } finally {
      _updateCheckInFlight = false;
    }
  }

  /// 修改自动检查频率。落到下次到点前，已挂起的提醒不受影响。
  Future<void> setUpdateCheckHours(int hours) =>
      updateSettings(settings.copyWith(updateCheckHours: hours));

  /// 手动「检查更新」成功后调用：刷新上次检查时间，与自动检查共用闸门，
  /// 避免刚手动查完、启动定时器又立刻重复查一次。
  Future<void> markManualUpdateCheck() async {
    await updateSettings(
      settings.copyWith(lastUpdateCheckMs: DateTime.now().millisecondsSinceEpoch),
    );
  }

  // ---------------------------------------------------------------------------
  // 设置
  // ---------------------------------------------------------------------------

  Future<void> updateSettings(WispSettings next, {bool restartNetwork = false}) async {
    final bool networkChanged = settings.alias != next.alias ||
        settings.visible != next.visible ||
        settings.encryption != next.encryption ||
        settings.pin != next.pin ||
        settings.pinEnabled != next.pinEnabled ||
        settings.port != next.port ||
        settings.networkInterface != next.networkInterface ||
        settings.discoveryMode != next.discoveryMode ||
        settings.scanIntervalSeconds != next.scanIntervalSeconds ||
        settings.username != next.username;
    settings = next;
    await _settingsService.save(next);
    notifyListeners();
    if (restartNetwork && networkChanged) {
      await _startNetwork();
    }
  }

  Future<void> setThemeMode(ThemeMode mode) => updateSettings(settings.copyWith(themeMode: mode));

  Future<void> setAlias(String alias) =>
      updateSettings(settings.copyWith(alias: alias.trim().isEmpty ? settings.alias : alias.trim()),
          restartNetwork: true);

  /// 设置识别用户名。留空表示不设限。
  Future<void> setUsername(String username) async {
    final String value = username.trim();
    await updateSettings(settings.copyWith(username: value));
    // 用户名变了，之前被过滤掉的设备可能重新可见，清干净重新筛。
    _filteredKeys.clear();
    notifyListeners();
  }

  /// 修改监听端口。同机跑多个 LocalSend 时用得上。
  Future<void> setPort(int port) => updateSettings(
        settings.copyWith(port: port),
        restartNetwork: true,
      );

  /// 指定使用哪块网卡。传 null 表示自动。
  Future<void> setNetworkInterface(String? interfaceId) async {
    await updateSettings(
      settings.copyWith(
        networkInterface: interfaceId,
        clearNetworkInterface: interfaceId == null,
      ),
      restartNetwork: true,
    );
    localIp = await DiscoveryService.resolveLocalIp(settings.networkInterface);
    notifyListeners();
  }

  Future<void> setDiscoveryMode(DiscoveryMode mode) =>
      updateSettings(settings.copyWith(discoveryMode: mode), restartNetwork: true);

  Future<void> setScanInterval(int seconds) =>
      updateSettings(settings.copyWith(scanIntervalSeconds: seconds), restartNetwork: true);

  Future<void> setMinimizeToTray(bool value) async {
    await updateSettings(settings.copyWith(minimizeToTray: value));
    // 同步给原生层：托盘开关是窗口行为，得让 C++ 那边也知道。
    await DesktopService.setMinimizeToTray(value);
  }

  /// 开关桌面悬浮球。关掉时原生层会销毁悬浮球和气泡窗口。
  Future<void> setFloatingBall(bool value) async {
    await updateSettings(settings.copyWith(floatingBall: value));
    await DesktopService.setFloatingBall(
      value,
      hoverDelayMs: settings.ballShowDelayMs,
      savedPosX: settings.ballPosX,
      savedPosY: settings.ballPosY,
      savedSnapped: settings.ballSnapped,
      savedEdge: settings.ballEdge,
    );
  }

  // ---------------------------------------------------------------------------
  // 服务守护（Windows 服务）
  // ---------------------------------------------------------------------------

  /// 守护服务状态：0=未安装 1=已安装未运行 2=运行中。
  int _serviceStatus = 0;
  int get serviceStatus => _serviceStatus;
  bool get serviceBusy => _serviceBusy;
  bool _serviceBusy = false;

  /// 安装/卸载守护服务。返回 false 表示没完成（常见：用户在 UAC 里取消）。
  Future<bool> setServiceGuard(bool install) async {
    if (_serviceBusy) return false;
    _serviceBusy = true;
    notifyListeners();
    try {
      final bool ok = install
          ? await DesktopService.installService()
          : await DesktopService.uninstallService();
      _serviceStatus = await DesktopService.serviceStatus();
      if (ok) {
        await updateSettings(
            settings.copyWith(installAsService: _serviceStatus != 0));
      }
      return ok;
    } finally {
      _serviceBusy = false;
      notifyListeners();
    }
  }

  /// 重启守护服务。返回 false 表示没完成（未安装、UAC 被取消、或服务卡在停止中）。
  Future<bool> restartServiceGuard() async {
    if (_serviceBusy) return false;
    _serviceBusy = true;
    notifyListeners();
    try {
      final bool ok = await DesktopService.restartService();
      _serviceStatus = await DesktopService.serviceStatus();
      return ok;
    } finally {
      _serviceBusy = false;
      notifyListeners();
    }
  }

  /// 悬浮球把手悬停多久自动展开（毫秒）。
  Future<void> setBallShowDelay(int ms) async {
    await updateSettings(settings.copyWith(ballShowDelayMs: ms));
    // 延时是窗口行为，同步给原生层。
    if (settings.floatingBall) {
      await DesktopService.setFloatingBall(true, hoverDelayMs: ms);
    }
  }

  Future<void> setVisible(bool visible) =>
      updateSettings(settings.copyWith(visible: visible), restartNetwork: true);

  Future<void> setEncryption(bool value) =>
      updateSettings(settings.copyWith(encryption: value), restartNetwork: true);

  Future<void> setPin(bool enabled, {String? pin}) => updateSettings(
        settings.copyWith(pinEnabled: enabled, pin: pin ?? settings.pin),
        restartNetwork: true,
      );

  Future<void> setAutoAccept(bool value) => updateSettings(settings.copyWith(autoAccept: value));

  Future<void> setSaveDirectory(String? path) =>
      updateSettings(settings.copyWith(saveDirectory: path));

  // ---------------------------------------------------------------------------
  // 待发送列表
  // ---------------------------------------------------------------------------

  void addFiles(List<TransferFile> files) {
    for (final TransferFile file in files) {
      final bool exists = draft.any((TransferFile f) => f.path == file.path && f.name == file.name);
      if (!exists) draft.add(file);
    }
    notifyListeners();
  }

  /// 拖拽进来的路径（原生层回调）：展开文件夹、并入待发清单，并通知外壳切到发送页。
  ///
  /// `composeTick` 是给 HomeShell 的信号——它只在变化时翻页，避免把"翻页"这件事
  /// 耦合进状态机，也避免用户在别的页面时被静默吞掉。
  Future<void> addDroppedPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    final List<TransferFile> incoming = <TransferFile>[];
    for (final String path in paths) {
      incoming.addAll(await Pickers.fromPaths(<String>[path]));
    }
    if (incoming.isEmpty) {
      banner = '拖进来的内容没有可发送的文件（快捷方式或没有读取权限）';
      notifyListeners();
      return;
    }
    final int before = draft.length;
    addFiles(incoming);
    final int added = draft.length - before;
    if (added == 0) {
      banner = '这些内容已经在待发清单里了';
      notifyListeners();
      return;
    }
    composeTick++;
    banner = added == 1 ? '已加入 1 个文件，选一台设备发出去' : '已加入 $added 个文件，选一台设备发出去';
    notifyListeners();
  }

  /// 把一条历史记录的源文件放回待发清单（不清空用户已经选好的内容）。
  /// 返回提示文案，null 表示已经放进去了。
  Future<String?> resendFromRecord(TransferRecord record) async {
    final List<TransferFile> files = <TransferFile>[];
    for (int i = 0; i < record.paths.length; i++) {
      final String path = record.paths[i];
      final File file = File(path);
      if (!file.existsSync()) continue;
      // 名字要用记录里那份：文件夹展开时它是「根目录/相对路径」，
      // 光看 path 会丢掉层级，接收端就还原不出目录结构了。
      final String name = i < record.fileNames.length
          ? record.fileNames[i]
          : path.split(Platform.pathSeparator).last;
      files.add(TransferFile(
        id: path,
        name: name,
        size: file.lengthSync(),
        path: path,
        mime: Pickers.mimeFor(name),
      ));
    }
    if (files.isEmpty) return '这些文件已经不在原来的位置了';
    final int before = draft.length;
    addFiles(files);
    final int added = draft.length - before;
    if (added == 0) {
      banner = '这些内容已经在待发清单里了';
      notifyListeners();
      return null;
    }
    preferredPeerIp = _peerIpFor(record);
    composeTick++;
    banner = added == 1 ? '已放回 1 个文件，选一台设备发出去' : '已放回 $added 个文件，选一台设备发出去';
    notifyListeners();
    return null;
  }

  /// 对端还在线就返回它的 IP，让发送页直接选中；不在线返回 null（用户自己挑）。
  String? _peerIpFor(TransferRecord record) {
    for (final WispDevice device in devices) {
      if (record.peerIp != null && device.ip == record.peerIp) return device.ip;
    }
    for (final WispDevice device in devices) {
      if (device.alias == record.peerAlias) return device.ip;
    }
    return null;
  }
  void removeFile(TransferFile file) {
    draft.remove(file);
    notifyListeners();
  }

  void clearDraft() {
    draft.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 发送
  // ---------------------------------------------------------------------------

  /// 发送端要如实上报本机端口与实际协议：对端拿这两个字段决定回连地址。
  /// 曾经写死 53317/https，改过端口或退回 HTTP 时对端会连错地方。
  SenderService _sender() => SenderService(
        alias: settings.alias,
        fingerprint: settings.fingerprint,
        deviceKind: settings.deviceKind.name,
        port: settings.port,
        secure: encrypted,
      );

  /// 发送到某台设备。返回错误文案（null 表示已发起或完成）。
  Future<String?> sendTo(WispDevice device, {String? pin}) async {
    if (draft.isEmpty) return '还没有选择文件';

    final TransferSession session = TransferSession(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(16),
      peerAlias: device.alias,
      peerIp: device.ip,
      direction: TransferDirection.outgoing,
      files: List<TransferFile>.from(draft),
      peerKind: device.kind,
      status: TransferStatus.pending,
    );
    sessions.insert(0, session);
    activeSession = session;
    notifyListeners();

    final SenderService sender = _sender();

    try {
      session.status = TransferStatus.waiting;
      notifyListeners();
      await sender.prepare(session, device, pin: pin);
      if (session.status == TransferStatus.completed) {
        _finishSession(session);
        return null;
      }
      await sender.uploadAll(
        session,
        device,
        onProgress: _throttleNotify,
        isCanceled: () => session.status == TransferStatus.canceled,
      );
      _finishSession(session);
      return null;
    } on SendFailure catch (e) {
      session.status = TransferStatus.failed;
      session.error = e.message;
      if (e.pinRequired) {
        // PIN 缺失不算失败：移除这条临时会话，等用户在弹窗里输入后重发。
        sessions.remove(session);
        activeSession = null;
      } else {
        _finishSession(session);
      }
      notifyListeners();
      return e.message;
    } catch (e) {
      session.status = TransferStatus.failed;
      session.error = '$e';
      _finishSession(session);
      return '连接失败，请确认双方在同一网络';
    }
  }

  Future<void> cancelSession(TransferSession session) async {
    session.cancel();
    notifyListeners();
    final WispDevice? device = devices.cast<WispDevice?>().firstWhere(
          (WispDevice? d) => d?.ip == session.peerIp,
          orElse: () => null,
        );
    if (device != null) {
      final SenderService sender = _sender();
      await sender.cancel(session, device);
    }
    _finishSession(session);
  }

  void _finishSession(TransferSession session) {
    // 取消和正常结束可能都会走到这里，用集合保证只记一次。
    if (!_finished.add(session.id)) return;
    // 这份集合只是去重用的，不能无限长。
    if (_finished.length > 256) {
      _finished
        ..clear()
        ..add(session.id);
    }
    if (session.status == TransferStatus.pending || session.status == TransferStatus.waiting) {
      session.status = TransferStatus.canceled;
    }
    final bool success = session.status == TransferStatus.completed;
    if (session.direction == TransferDirection.outgoing && success) {
      draft.clear();
    }
    final TransferRecord record = TransferRecord(
      id: session.id,
      peerAlias: session.peerAlias,
      direction: session.direction,
      fileNames: session.files.map((TransferFile f) => f.name).toList(),
      bytes: session.doneBytes,
      time: DateTime.now(),
      success: success,
      // 出站记源文件路径（"再次发送"要用），入站记落盘目录（"打开目录"要用）。
      // 用空字符串占位而不是过滤掉，保证 paths 与 fileNames 的下标严格对齐，
      // 否则重发时文件名会整体错位一格。
      paths: session.direction == TransferDirection.outgoing
          ? session.files.map((TransferFile f) => f.path ?? '').toList()
          : const <String>[],
      saveDir: session.saveDir,
      peerIp: session.peerIp,
    );
    history.insert(0, record);
    // 磁盘上本来只留 120 条，但内存里的 history 之前是只增不减——
    // 挂机跑几百次传输之后，这份列表会一直涨。这里同步截断。
    if (history.length > HistoryService.limit) {
      history.removeRange(HistoryService.limit, history.length);
    }
    // 结束的会话不必再留在内存里：sessions 只为进行中的传输服务。
    sessions.removeWhere(
        (TransferSession s) => s != session && s.status.isFinished);
    unawaited(_historyService.save(history));
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 接收
  // ---------------------------------------------------------------------------

  /// 收到接收请求的统一入口：网络回调和自测都走这里。
  ///
  /// 单独抽出来是为了让自测能驱动**真实**的通知分流逻辑
  /// （decideIncomingSurface + 桌面流程状态机），而不是绕过它直接调原生通道——
  /// 绕过的那条路测不出"第一次不出现、第二次才出现"这类问题。
  void handleIncomingRequest(IncomingRequest request) {
    incoming = request;
    // 每次都是全新的一条流程：先把上一条流程的桌面状态清干净。
    _bubbleShown = false;
    _bubbleAccepted = false;
    _toastShown = false;
    _progressSurfaceShown = false;
    _desktopSuppressed = false;
    unawaited(_notifyDesktopIncoming(request));
    notifyListeners();
  }

  /// 传输结束后的桌面收尾（网络层和自测都走这里）。
  void handleTransferFinished(TransferSession session) {
    _notifyDesktopFinished(session);
  }

  void acceptIncoming({Set<String>? fileIds}) {
    incoming?.resolve(ReceiveDecision.accept(fileIds: fileIds));
    incoming = null;
    unawaited(DesktopService.setTrayFlashing(false));
    // 用户走应用内弹层确认的：把还挂在桌面的"询问"气泡收掉。
    // 用户从气泡上确认的（_bubbleAccepted）不动，气泡马上要切进度条。
    if (_bubbleShown && !_bubbleAccepted) {
      _bubbleShown = false;
      unawaited(DesktopService.hideBubble());
    }
    notifyListeners();
  }

  void rejectIncoming() {
    incoming?.resolve(const ReceiveDecision.reject());
    incoming = null;
    unawaited(DesktopService.setTrayFlashing(false));
    // 气泡 dismiss 路径 C++ 已自己收起，这里再调一次是无害的兜底。
    if (_bubbleShown) {
      _bubbleShown = false;
      _bubbleAccepted = false;
      unawaited(DesktopService.hideBubble());
    }
    _toastShown = false;
    // 拒绝即流程结束：吸附的球缩回把手。
    unawaited(DesktopService.collapseBall());
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 桌面集成：托盘闪烁 / 通知卡片 / 悬浮球气泡
  // ---------------------------------------------------------------------------

  /// 收到接收请求时的桌面提醒分流（互斥，绝不重复打扰）：
  /// * 主窗口开着且是当前激活窗口 → 什么都不做，应用内弹层就是通知；
  /// * 悬浮球启用 → 唤醒悬浮球 + 旁边气泡（不弹卡片）；
  /// * 其它（主窗口没开 / 开着但被切走）→ 托盘闪烁 + 右下角通知卡片。
  ///
  /// 判定逻辑集中在 [decideIncomingSurface]，这里是唯一的调用点。
  Future<void> _notifyDesktopIncoming(IncomingRequest request) async {
    final DesktopWindowState state = await DesktopService.windowState();
    final NotificationSurface surface = decideIncomingSurface(state);
    if (surface == NotificationSurface.inApp) return;

    final int total = request.files.fold(0, (int sum, TransferFile f) => sum + f.size);
    final String body =
        '${request.sender.alias} 想发送 ${request.files.length} 个文件（${Format.bytes(total)}）';
    await DesktopService.setTrayFlashing(true);
    _useBallForFlow = useBallFlow(surface);
    if (_useBallForFlow) {
      await DesktopService.showBallAlert();
      _bubbleShown = true;
      _bubbleAccepted = false;
      await _desktopNotice(
        onBall: true,
        title: request.sender.alias,
        body: '想发送 ${request.files.length} 个文件（${Format.bytes(total)}），是否接收？',
        mode: DesktopService.bubbleAsk,
      );
    } else {
      _toastShown = true;
      await _desktopNotice(
        onBall: false,
        title: '收到传输请求',
        body: body,
        mode: DesktopService.bubbleAsk,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 桌面浮层的"发 → 查 → 没出来就重发"闭环
  // ---------------------------------------------------------------------------

  /// 点悬浮球时补弹询问气泡（请求还在、但球侧还没弹过）。
  void _showIncomingBubble(IncomingRequest request) {
    final int total =
        request.files.fold(0, (int sum, TransferFile f) => sum + f.size);
    _bubbleShown = true;
    _bubbleAccepted = false;
    unawaited(_desktopNotice(
      onBall: true,
      title: request.sender.alias,
      body: '想发送 ${request.files.length} 个文件（${Format.bytes(total)}），是否接收？',
      mode: DesktopService.bubbleAsk,
    ));
  }

  /// 让某条桌面通道显示一段内容。
  ///
  /// * [isUpdate]=true：在已经弹出的那张卡/气泡上改内容；
  /// * [isUpdate]=false：全新弹一张。
  ///
  /// 两条硬约束，都是用户投诉过的：
  /// 1. 弹完必须**确认它真的画出来了**（visible + drawn）。以前是"发一次就
  ///    当成功"，原生层没画出来时这一次请求就悄无声息地过去了，用户得等
  ///    下一次请求才看到通知——也就是"要第二次才会出现"。
  /// 2. 改内容时如果原来那张已经不在了（超时收掉了），必须改成全新弹一张；
  ///    否则 update 是空操作，发送方取消/传输完成这类结局提示会被吞掉。
  Future<void> _desktopNotice({
    required bool onBall,
    required String title,
    required String body,
    required int mode,
    bool isUpdate = false,
    String progress = '',
  }) async {
    final String which = onBall ? 'bubble' : 'toast';
    if (isUpdate && await _surfaceReady(which)) {
      if (onBall) {
        await DesktopService.updateBubble(body, mode: mode, progress: progress);
      } else {
        await DesktopService.updateToast(body, mode: mode, progress: progress);
      }
      if (await _surfaceReady(which)) return;
      // 更新没生效（那张刚好被收走了），落到下面重新弹一张。
    }
    for (int attempt = 0; attempt < 2; attempt++) {
      if (onBall) {
        await DesktopService.showBubble(title, body, mode: mode, progress: progress);
      } else {
        await DesktopService.showToast(title, body, mode: mode, progress: progress);
      }
      if (await _surfaceReady(which)) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  /// 原生层确认某个浮层已经真的画出来了。
  ///
  /// 只看 visible 会被"窗口在、内容空"骗过去，所以两个条件都要满足。
  Future<bool> _surfaceReady(String which) async {
    final Map<String, Object?> status = await DesktopService.surfaceStatus();
    final Object? raw = status[which];
    if (raw is! Map) return false;
    return raw['visible'] == true && raw['drawn'] == true;
  }

  /// 接收中的高频进度回调：同步刷新进度面板（200ms 节流）。
  /// 确认后的第一跳负责把面板创建出来（气泡或卡片，跟随本次流程）。
  void _updateDesktopProgress(TransferSession session) {
    if (!_bubbleAccepted || session.direction != TransferDirection.incoming) return;
    if (session.status.isFinished || _desktopSuppressed) return;
    final DateTime now = DateTime.now();
    if (_progressSurfaceShown &&
        now.difference(_lastBubbleUpdate).inMilliseconds < 200) {
      return;
    }
    _lastBubbleUpdate = now;
    final int percent = (session.progress * 100).round();
    final String speed = session.bytesPerSecond > 0
        ? ' · ${Format.bytes(session.bytesPerSecond)}/s'
        : '';
    final String progress = '$percent%$speed';
    if (!_progressSurfaceShown) {
      _progressSurfaceShown = true;
      unawaited(_desktopNotice(
        onBall: _useBallForFlow,
        title: '正在接收',
        body: '${session.peerAlias} 发来的 ${session.files.length} 个文件',
        mode: DesktopService.bubbleProgress,
        progress: progress,
      ));
    } else {
      unawaited(_desktopNotice(
        onBall: _useBallForFlow,
        title: '正在接收',
        body: '正在接收 ${session.peerAlias} 的 ${session.files.length} 个文件…',
        mode: DesktopService.bubbleProgress,
        progress: progress,
        isUpdate: true,
      ));
    }
  }

  /// 接收流程结束：完成态切"打开目录"，取消/中断态显示提示
  /// （原生层 3 秒后自动收起）；悬浮球缩回把手。
  void _notifyDesktopFinished(TransferSession session) {
    if (session.direction != TransferDirection.incoming) return;
    // 本次流程有没有在桌面上露过面：气泡确认过 / 卡片在展 / 询问气泡在展。
    // 什么都没露过（比如用户全程看着主窗口）就不必打扰。
    final bool surfaceActive = _bubbleAccepted || _toastShown || _bubbleShown;
    final bool flowOnBall = _useBallForFlow;
    _bubbleShown = false;
    _bubbleAccepted = false;
    _toastShown = false;
    _progressSurfaceShown = false;
    if (_desktopSuppressed || !surfaceActive) {
      unawaited(DesktopService.collapseBall());
      return;
    }
    if (session.status == TransferStatus.completed) {
      unawaited(_desktopNotice(
        onBall: flowOnBall,
        title: '接收完成',
        body: '${session.files.length} 个文件已保存，是否打开保存目录？',
        mode: DesktopService.bubbleDone,
      ));
    } else {
      // 发送方取消（/cancel）或连接中断：在原卡片上显示提示，
      // 原生层按 mode=canceled 的存活时间（3 秒）自动收起，回到原状态。
      // 原来那张卡要是已经超时收掉了，就新弹一张——不然这条提示会被吞掉，
      // 用户根本不知道传输结束了。
      final String hint = session.status == TransferStatus.canceled
          ? '${session.peerAlias} 取消了发送'
          : '与 ${session.peerAlias} 的连接中断，传输未完成';
      unawaited(_desktopNotice(
        onBall: flowOnBall,
        title: '传输已结束',
        body: hint,
        mode: DesktopService.bubbleCanceled,
        isUpdate: true,
      ));
    }
    unawaited(DesktopService.collapseBall());
  }

  /// 原生层推回的事件统一入口。
  Future<void> _onDesktopEvent(String event, Map<Object?, Object?> args) async {
    switch (event) {
      case 'onBallPosition':
        // 拖动结束：记住球的最终位置，下次启用时原样恢复。
        final Object? bx = args['x'];
        final Object? by = args['y'];
        final Object? bs = args['snapped'];
        final Object? be = args['edge'];
        if (bx is int && by is int) {
          await updateSettings(settings.copyWith(
            ballPosX: bx,
            ballPosY: by,
            ballSnapped: bs is bool ? bs : false,
            ballEdge: be is int ? be : -1,
          ));
        }
        break;
      case 'onBallClicked':
        // 有待处理的请求就在球旁边弹询问气泡，否则把主窗口叫回来。
        final IncomingRequest? request = incoming;
        if (request != null) {
          _showIncomingBubble(request);
        } else {
          await DesktopService.showWindow();
        }
      case 'onWindowRestored':
        // 用户回到主窗口：桌面提醒退场，后续进度/完成由主窗口呈现。
        _desktopSuppressed = true;
        _bubbleShown = false;
        _bubbleAccepted = false;
        _toastShown = false;
      case 'onBubbleAction':
        final String action = args['action']?.toString() ?? '';
        if (action == 'accept' && incoming != null) {
          _bubbleAccepted = true;
          _progressSurfaceShown = false;
          acceptIncoming();
        } else if (action == 'dismiss') {
          rejectIncoming();
        } else if (action == 'openFolder') {
          await _openSaveFolder();
        }
      case 'onFilesDropped':
        // 主窗口接到拖拽：路径交给状态机展开、入清单，外壳会切到发送页。
        final Object? raw = args['paths'];
        if (raw is List<Object?>) {
          await addDroppedPaths(raw.whereType<String>().toList());
        }
      case 'onToastClicked':
        // C++ 层已恢复窗口并停掉闪烁/卡片，这里同步状态即可。
        _desktopSuppressed = true;
        _bubbleShown = false;
        _bubbleAccepted = false;
        _toastShown = false;
        break;
      case 'onBubbleTimeout':
        // 询问态超时算用户没表态：球缩回把手，流程结束。
        if (!_bubbleAccepted) {
          _bubbleShown = false;
          unawaited(DesktopService.collapseBall());
        }
    }
  }

  /// 打开接收目录。用户没配置就用 下载/Wisp，和接收端逻辑保持一致。
  Future<void> _openSaveFolder() async {
    String? path = settings.saveDirectory;
    if (path == null || path.isEmpty || !Directory(path).existsSync()) {
      final Directory? downloads = await getDownloadsDirectory();
      path = downloads == null
          ? null
          : '${downloads.path}${Platform.pathSeparator}Wisp';
    }
    if (path == null || !Directory(path).existsSync()) return;
    await _openDirectory(path);
  }

  /// 用系统文件管理器打开一个目录。三平台各自的原生命令。
  Future<void> _openDirectory(String path) async {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', <String>[path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', <String>[path]);
    }
  }

  // ---------------------------------------------------------------------------
  // 历史
  // ---------------------------------------------------------------------------

  /// 打开某条历史记录对应的目录：入站用它当时的落盘目录，
  /// 出站用源文件所在目录（文件被移走就提示，不猜）。
  Future<void> openRecordFolder(TransferRecord record) async {
    String? dir;
    final String? saved = record.saveDir;
    if (saved != null && Directory(saved).existsSync()) dir = saved;
    if (dir == null) {
      final List<String> existing = record.existingPaths;
      if (existing.isNotEmpty) dir = File(existing.first).parent.path;
    }
    if (dir == null) {
      banner = '这些文件已经不在原来的位置了';
      notifyListeners();
      return;
    }
    await _openDirectory(dir);
  }

  void removeHistory(String id) {
    history.removeWhere((TransferRecord r) => r.id == id);
    unawaited(_historyService.save(history));
    notifyListeners();
  }

  void clearHistory() {
    history.clear();
    unawaited(_historyService.save(history));
    notifyListeners();
  }

  /// 手动输入 IP 连接（组播被墙时的最后手段）。
  Future<String?> connectManually(String input) async {
    final String target = input.trim();
    if (target.isEmpty) return '请输入 IP 地址';
    final RegExp ipv4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
    if (!ipv4.hasMatch(target)) return 'IP 格式不正确';

    for (final String scheme in <String>['https', 'http']) {
      try {
        final HttpClient client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 2)
          ..badCertificateCallback = (X509Certificate c, String h, int p) => true;
        final Uri uri = Uri.parse('$scheme://$target:${settings.port}${WispProtocol.infoPath}');
        final HttpClientRequest request = await client.getUrl(uri);
        final HttpClientResponse response = await request.close();
        if (response.statusCode != 200) continue;
        final String body = await response.transform(utf8.decoder).join();
        client.close(force: true);
        if (body.isEmpty) continue;
        final Object? decoded = jsonDecode(body);
        final Map<String, dynamic> payload = decoded is Map<String, dynamic>
            ? <String, dynamic>{...decoded, 'protocol': scheme}
            : <String, dynamic>{'alias': target, 'protocol': scheme};
        _upsertDevice(WispDevice.fromJson(payload, ip: target));
        return null;
      } catch (_) {
        continue;
      }
    }
    return '连不上 $target，请检查端口 53317 是否被拦截';
  }

  @override
  void dispose() {
    _sweepTimer?.cancel();
    _updateTimer?.cancel();
    _discovery?.dispose();
    _receiver?.dispose();
    super.dispose();
  }
}
