import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../core/username_scope.dart';
import '../core/file_names.dart';
import '../models/device.dart';
import '../models/message.dart';
import '../models/transfer.dart';
import 'discovery_service.dart';
import 'settings_service.dart';
import 'tls_service.dart';

/// 对方发来的传输请求，等待用户点"接收"。
class IncomingRequest {
  IncomingRequest({required this.sender, required this.files});

  final WispDevice sender;
  final List<TransferFile> files;
  final Completer<ReceiveDecision> _completer = Completer<ReceiveDecision>();

  Future<ReceiveDecision> get decision => _completer.future;
  bool get isResolved => _completer.isCompleted;

  void resolve(ReceiveDecision decision) {
    if (!_completer.isCompleted) _completer.complete(decision);
  }
}

class ReceiveDecision {
  const ReceiveDecision.accept({this.fileIds, this.pin})
      : rejected = false,
        pinRequired = false;

  const ReceiveDecision.reject()
      : rejected = true,
        pinRequired = false,
        fileIds = null,
        pin = null;

  const ReceiveDecision.pinRequired()
      : rejected = false,
        pinRequired = true,
        fileIds = null,
        pin = null;

  final bool rejected;
  final bool pinRequired;
  final Set<String>? fileIds;
  final String? pin;
}

/// 接收端 HTTP 服务：实现协议 v2.2 的 register / prepare-upload / upload / cancel。
///
/// 有证书就走 HTTPS（对应设置里的"加密传输"），没有证书退回 HTTP，
/// 但依然只在局域网内可达，不做任何中继。
class ReceiverService {
  ReceiverService({
    required this.settings,
    required this.onIncoming,
    required this.onProgress,
    required this.onFinished,
    required this.onLog,
    required this.onMessage,
    this.onRegistered,
  });

  final WispSettings settings;
  final Future<ReceiveDecision> Function(IncomingRequest request) onIncoming;
  final void Function(TransferSession session) onProgress;
  final void Function(TransferSession session) onFinished;
  final void Function(String message) onLog;

  /// 收到一条文字/剪贴板消息（官方 LocalSend 的 prepare-upload + preview）。
  ///
  /// 与文件接收完全分离：不经过 [onIncoming] 的"接受/拒绝"确认，
  /// 也不产生 [TransferSession]、不写盘。消息像 IM 一样直接落到会话里。
  final void Function(IncomingMessage message) onMessage;

  /// 对方主动来握手（单播 HTTP register）时回调。
  ///
  /// 这一步是双向发现的关键一环：官方 LocalSend 收到我们的组播广播后，
  /// **只会**用单播 HTTP 回应，不会在组播里再发一遍。
  /// 之前这里只打了条日志就丢掉，结果就是"谁也发现不了"。
  final void Function(WispDevice device)? onRegistered;

  HttpServer? _server;
  final Map<String, _ReceiveSession> _sessions = <String, _ReceiveSession>{};
  final Map<String, String> _tokenIndex = <String, String>{};

  bool get isRunning => _server != null;
  bool get isSecure => _secure;

  /// 实际监听端口。`settings.port` 为 0（让系统挑空闲口）时，
  /// 绑定完成后从这里读真实值。
  int? get boundPort => _server?.port;

  bool _secure = false;

  Future<void> start() async {
    if (_server != null) return;
    final SecurityContext? context = settings.encryption ? await WispTls.context() : null;
    try {
      if (context != null) {
        _server = await HttpServer.bindSecure(InternetAddress.anyIPv4, settings.port, context);
        _secure = true;
      } else {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, settings.port);
        _secure = false;
      }
      _server!.idleTimeout = const Duration(seconds: 30);
      unawaited(_listen());
    } on SocketException catch (e) {
      onLog('接收服务启动失败：${e.osError?.message ?? e.message}');
    }
  }

  /// 停止接收。改端口、退出应用时用；会话一并作废，
  /// 未完成的传输 token 随之失效——对端会拿到 403，符合预期。
  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    _secure = false;
    _sessions.clear();
    _tokenIndex.clear();
    await server?.close(force: true);
  }

  /// 证书来自 assets/certs（见 [WispTls]）；缺失时退回 HTTP。
  Future<void> _listen() async {
    final HttpServer? server = _server;
    if (server == null) return;
    await for (final HttpRequest request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final String path = request.uri.path;
    try {
      switch (path) {
        case WispProtocol.registerPath:
          await _handleRegister(request);
          return;
        case WispProtocol.infoPath:
          await _json(request, 200, _selfInfo());
          return;
        case WispProtocol.prepareUploadPath:
          await _handlePrepare(request);
          return;
        case WispProtocol.uploadPath:
          await _handleUpload(request);
          return;
        case WispProtocol.cancelPath:
          await _handleCancel(request);
          return;
        default:
          await _json(request, 404, <String, dynamic>{'message': 'not found'});
      }
    } catch (e) {
      onLog('请求处理失败（$path）：$e');
      await _json(request, 500, <String, dynamic>{'message': 'internal error'});
    }
  }

  Map<String, dynamic> _selfInfo() => <String, dynamic>{
        'alias': settings.alias,
        'version': WispProtocol.version,
        'deviceModel': DiscoveryService.platformLabel(),
        'deviceType': settings.deviceKind.name,
        'fingerprint': settings.fingerprint,
        'port': settings.port,
        'protocol': _secure ? 'https' : 'http',
        'download': false,
        if (settings.hasUsername) 'username': settings.username.trim(),
      };

  Future<void> _handleRegister(HttpRequest request) async {
    final String body = await utf8.decoder.bind(request).join();
    final Map<String, dynamic>? payload = _decode(body);
    final String remoteIp = request.connectionInfo?.remoteAddress.address ?? '';

    // 用户名不同就装作这里没有服务：连"我们是谁"都不回。
    // 只做界面过滤远远不够——对方扫一遍网段，凭 200 响应就知道我们在。
    final String theirs = (payload?['username'] as String?) ?? '';
    if (!sameUsernameScope(settings.username, theirs)) {
      onLog('拒绝 $remoteIp 的发现请求：用户名不一致'
          '（本机「${_scopeLabel()}」，对方「${theirs.trim().isEmpty ? '未设置' : theirs.trim()}」）');
      await _json(request, 403, <String, dynamic>{'message': 'username mismatch'});
      return;
    }

    // 对方主动来握手 —— 这就是官方 LocalSend 的发现回应方式。
    // 之前这里只打日志就丢掉了，导致双方互相看不见。
    if (payload != null) {
      // register 响应里通常不带 port，用 TCP 源端口补上（对方服务监听的那个端口）。
      final int remotePort = (payload['port'] as num?)?.toInt() ??
          request.connectionInfo?.remotePort ??
          settings.port;
      final WispDevice device =
          WispDevice.fromJson(payload, ip: remoteIp).copyWith(port: remotePort);
      onRegistered?.call(device);
    }
    await _json(request, 200, _selfInfo());
  }

  /// 日志里怎么称呼本机的用户名范围。
  String _scopeLabel() => settings.hasUsername ? settings.username.trim() : '未设置';

  Future<void> _handlePrepare(HttpRequest request) async {
    final String body = await utf8.decoder.bind(request).join();
    final Map<String, dynamic>? payload = _decode(body);
    if (payload == null) {
      await _json(request, 400, <String, dynamic>{'message': 'invalid body'});
      return;
    }

    final String remoteIp = request.connectionInfo?.remoteAddress.address ?? '';
    final Map<String, dynamic> info = (payload['info'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final Map<String, dynamic> rawFiles = (payload['files'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    if (rawFiles.isEmpty) {
      await _json(request, 204, <String, dynamic>{});
      return;
    }

    final List<TransferFile> files = rawFiles.entries
        .map((MapEntry<String, dynamic> e) =>
            TransferFile.fromProtocolJson(e.key, (e.value as Map<String, dynamic>?) ?? <String, dynamic>{}))
        .toList();

    final WispDevice sender = WispDevice.fromJson(info, ip: remoteIp);

    // 入站请求里的 `request.certificate` 只有在服务端**主动索取客户端证书**
    // 时才非空；Dart 的 HttpClient 不支持配置客户端证书，所以我们从不索取，
    // 这里实际上恒为 null。保留这段是为了将来真做 mTLS 时能直接生效，
    // 但**不要**把它当成"接收端已经验证了发送方身份"——现在的接收端做不到。
    final bool? certOk =
        WispTls.certMatchesClaim(request.certificate, info['fingerprint'] as String?);
    if (certOk == false) {
      onLog('拒绝 $remoteIp 的请求：证书与它声明的指纹不一致');
      await _json(request, 403, <String, dynamic>{'message': 'certificate mismatch'});
      return;
    }

    // 用户名不同直接拒绝。发现阶段两边已经互相看不见了，这里再挡一道，
    // 防止有人拿着旧记录（或从组播报文里看到的地址）绕过发现直接推文件。
    if (!sameUsernameScope(settings.username, sender.username)) {
      onLog('拒绝 $remoteIp 的传输请求：用户名不一致'
          '（本机「${_scopeLabel()}」，对方「${sender.username.trim().isEmpty ? '未设置' : sender.username.trim()}」）');
      await _json(request, 403, <String, dynamic>{'message': 'username mismatch'});
      return;
    }

    // 官方 LocalSend 的文字/剪贴板消息：prepare-upload 里恰好一个 text/plain
    // 文件、正文内联在 preview。刻意放在证书/用户名校验之后、PIN 校验之前：
    // 消息不写盘、不询问、不建会话，PIN 的语义是"往磁盘写文件"，对消息不适用；
    // 但证书指纹与用户名范围仍照常生效。接收端一个文件都不接、回 204。
    final bool isTextMessage = files.length == 1 &&
        files.first.mime == WispProtocol.textFileType &&
        files.first.preview != null;
    if (isTextMessage) {
      final String text = files.first.preview!;
      if (text.trim().isEmpty) {
        await _json(request, 400, <String, dynamic>{'message': 'empty message'});
        return;
      }
      if (text.length > WispProtocol.maxMessageChars) {
        await _json(request, 413, <String, dynamic>{'message': 'message too large'});
        return;
      }
      // 官方消息报文没有时间字段，以收到时间为准。
      onMessage(IncomingMessage(
        id: files.first.id,
        text: text,
        time: DateTime.now(),
        sender: sender,
      ));
      await _json(request, 204, <String, dynamic>{});
      return;
    }

    // PIN 校验：协议里 PIN 走 query，缺失或错误都回 401。
    if (settings.pinEnabled && settings.pin.isNotEmpty) {
      final String? pin = request.uri.queryParameters['pin'];
      if (pin != settings.pin) {
        await _json(request, 401, <String, dynamic>{'message': 'pin required'});
        return;
      }
    }

    final IncomingRequest incoming = IncomingRequest(sender: sender, files: files);
    // 免确认白名单按 fingerprint（对端自报值，是"免打扰"不是身份认证）判定，
    // 且文件数/字节数必须在护栏内；超限回落询问，防被灌盘。PIN / 用户名范围 /
    // 证书校验都在上面独立执行，自动接收不会绕过它们。
    final bool autoAccept = settings.shouldAutoAccept(
      fingerprint: sender.fingerprint,
      fileCount: files.length,
      totalBytes: files.fold<int>(0, (int s, TransferFile f) => s + f.size),
    );
    final ReceiveDecision decision = autoAccept
        ? ReceiveDecision.accept(fileIds: files.map((TransferFile f) => f.id).toSet())
        : await onIncoming(incoming);

    if (decision.rejected) {
      await _json(request, 403, <String, dynamic>{'message': 'rejected'});
      return;
    }
    if (decision.pinRequired) {
      await _json(request, 401, <String, dynamic>{'message': 'pin required'});
      return;
    }

    final Set<String> accepted =
        decision.fileIds ?? files.map((TransferFile f) => f.id).toSet();
    if (accepted.isEmpty) {
      // 协议 4.1 "Finished (No file transfer needed)"：一个文件都不接就回 204，
      // 官方空 accept 正是这个语义；不要回 403 把正常空清单误判成"拒绝"。
      await _json(request, 204, <String, dynamic>{});
      return;
    }

    final String sessionId = _newId();
    final List<TransferFile> acceptedFiles =
        files.where((TransferFile f) => accepted.contains(f.id)).toList();
    final TransferSession session = TransferSession(
      id: sessionId,
      peerAlias: sender.alias,
      peerIp: sender.ip,
      direction: TransferDirection.incoming,
      files: acceptedFiles,
      peerKind: sender.kind,
      status: TransferStatus.active,
      peerFingerprint: sender.fingerprint,
    );

    final Map<String, String> tokens = <String, String>{};
    for (final TransferFile file in acceptedFiles) {
      final String token = _newId();
      tokens[file.id] = token;
      session.tokens[file.id] = token;
      _tokenIndex['$sessionId:${file.id}'] = token;
    }

    final Directory dir = await _resolveDirectory();
    session.saveDir = dir.path;
    _sessions[sessionId] = _ReceiveSession(session: session, directory: dir);
    onProgress(session);

    await _json(request, 200, <String, dynamic>{'sessionId': sessionId, 'files': tokens});
  }

  Future<void> _handleUpload(HttpRequest request) async {
    final String? sessionId = request.uri.queryParameters['sessionId'];
    final String? fileId = request.uri.queryParameters['fileId'];
    final String? token = request.uri.queryParameters['token'];

    if (sessionId == null || fileId == null || token == null) {
      await _json(request, 400, <String, dynamic>{'message': 'missing parameters'});
      return;
    }
    final _ReceiveSession? session = _sessions[sessionId];
    if (session == null) {
      onLog('上传被拒（403）：会话 $sessionId 不存在或已过期');
      await _json(request, 403, <String, dynamic>{'message': 'invalid session'});
      return;
    }
    if (_tokenIndex['$sessionId:$fileId'] != token) {
      onLog('上传被拒（403）：文件 $fileId 的 token 不匹配');
      await _json(request, 403, <String, dynamic>{'message': 'invalid token'});
      return;
    }

    final TransferFile? file = session.session.files
        .cast<TransferFile?>()
        .firstWhere((TransferFile? f) => f?.id == fileId, orElse: () => null);
    if (file == null) {
      await _json(request, 403, <String, dynamic>{'message': 'unknown file'});
      return;
    }

    final File target = await session.reserve(file.name);
    final IOSink sink = target.openWrite();
    final _DigestSink digestSink = _DigestSink();
    final ByteConversionSink hasher = sha256.startChunkedConversion(digestSink);

    try {
      await for (final List<int> chunk in request) {
        sink.add(chunk);
        hasher.add(chunk);
        file.sent += chunk.length;
        session.session.sample();
        onProgress(session.session);
      }
      await sink.flush();
      await sink.close();
      hasher.close();

      final String? expected = file.sha256;
      final String? actual = digestSink.value?.toString();
      if (expected != null && expected.isNotEmpty && actual != expected) {
        if (await target.exists()) await target.delete();
        await _json(request, 422, <String, dynamic>{'message': 'checksum mismatch'});
        return;
      }

      // 校验通过才记：这个 fileId 的真实落盘路径（safeFileName 改名 / 重名
      // 加后缀后的路径）。放在 onFinished 之前，保证生成历史记录时已填好；
      // 失败或校验不符时绝不记录。
      session.session.savedPaths[fileId] = target.path;

      session.session.status = session.session.progress >= 1
          ? TransferStatus.completed
          : TransferStatus.active;
      request.response.statusCode = 200;
      await request.response.close();

      if (session.session.status == TransferStatus.completed) {
        if (session.markFinished()) onFinished(session.session);
        _dropSession(sessionId);
      }
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {
        // sink 已经坏了，忽略。
      }
      // 半截文件没有任何用处，留在下载目录里只会越堆越多——直接删掉。
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {
        // 文件被占用之类，删不掉就算了。
      }
      session.session.status = TransferStatus.failed;
      session.session.error = '$e';
      if (session.markFinished()) onFinished(session.session);
      _dropSession(sessionId);
      await _json(request, 500, <String, dynamic>{'message': 'write failed'});
    }
  }

  Future<void> _handleCancel(HttpRequest request) async {
    final String? sessionId = request.uri.queryParameters['sessionId'];
    if (sessionId != null) {
      final _ReceiveSession? session = _sessions[sessionId];
      if (session != null) {
        _dropSession(sessionId);
        session.session.status = TransferStatus.canceled;
        if (session.markFinished()) onFinished(session.session);
      }
    }
    request.response.statusCode = 200;
    await request.response.close();
  }

  /// 读请求体，超过 [limit] 字节就放弃（返回 null）。
  ///
  /// 不能直接 `utf8.decoder.bind(request).join()`：对端可以用 chunked 编码
  /// 声明一个假的 Content-Length，或者干脆不声明，join 会一直读到内存爆掉。
  ///
  /// 私有文字消息端点退役后这里暂时没有调用点，但保留给将来任何"带 body
  /// 上限"的端点复用，别删。
  // ignore: unused_element
  Future<String?> _readCapped(HttpRequest request, int limit) async {
    // contentLength 未知时是 -1，比较自然不成立，落到下面的流式计数。
    if (request.contentLength > limit) return null;
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in request) {
      builder.add(chunk);
      if (builder.length > limit) return null;
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<Directory> _resolveDirectory() async {
    final String? configured = settings.saveDirectory;
    if (configured != null && configured.isNotEmpty) {
      final Directory dir = Directory(configured);
      if (await dir.exists()) return dir;
    }
    // path_provider 在个别平台上会抛"不支持"而不是返回 null，
    // 兜底逐级降级：下载目录 → 文档目录 → 系统临时目录，总之要有个能落盘的地方。
    try {
      final Directory? downloads = await getDownloadsDirectory();
      if (downloads != null) {
        final Directory wisp = Directory('${downloads.path}${Platform.pathSeparator}Wisp');
        if (!await wisp.exists()) await wisp.create(recursive: true);
        return wisp;
      }
      final Directory docs = await getApplicationDocumentsDirectory();
      return docs;
    } catch (_) {
      final Directory temp =
          Directory('${Directory.systemTemp.path}${Platform.pathSeparator}Wisp');
      if (!await temp.exists()) await temp.create(recursive: true);
      return temp;
    }
  }

  Map<String, dynamic>? _decode(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<void> _json(HttpRequest request, int status, Map<String, dynamic> body) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    if (body.isNotEmpty) request.response.write(jsonEncode(body));
    await request.response.close();
  }

  String _newId() {
    final int now = DateTime.now().microsecondsSinceEpoch;
    return now.toRadixString(16) + (now % 977).toRadixString(16);
  }

  /// 丢掉一个接收会话，同时把它的文件 token 一起清掉。
  ///
  /// token 索引是跟着会话走的：只删会话不删 token，这张表会随着每次传输
  /// 单调变大，长期挂着不关的客户端会慢慢吃掉内存。
  void _dropSession(String sessionId) {
    _sessions.remove(sessionId);
    final String prefix = '$sessionId:';
    _tokenIndex.removeWhere((String key, String _) => key.startsWith(prefix));
  }

  Future<void> dispose() async {
    for (final _ReceiveSession session in _sessions.values) {
      session.session.cancel();
    }
    _sessions.clear();
    _tokenIndex.clear();
    await _server?.close(force: true);
    _server = null;
  }
}

class _ReceiveSession {
  _ReceiveSession({required this.session, required this.directory});

  final TransferSession session;
  final Directory directory;
  final Set<String> _used = <String>{};
  bool _finished = false;

  /// 完成回调只允许发一次，返回这次是否轮到它。
  ///
  /// 发送端是两个 worker 并发上传的，多个文件几乎同时结束时都会看到
  /// `progress >= 1`，各自回调一次——接收端历史里就会出现两条一模一样的
  /// 记录。这里用一次性闸门收口。
  bool markFinished() {
    if (_finished) return false;
    _finished = true;
    return true;
  }

  /// 同名文件不覆盖，追加 (1)(2) 后缀。
  ///
  /// [name] 来自对端报文，**不可信**：先过 [safeFileName] 收成纯文件名，
  /// 再由 [_child] 兜底断言落点仍在会话目录内。
  Future<File> reserve(String name) async {
    final String safe = safeFileName(name);
    String candidate = safe;
    int index = 1;
    File target = _child(candidate);
    while (_used.contains(candidate) || await target.exists()) {
      final int dot = safe.lastIndexOf('.');
      candidate = dot <= 0
          ? '$safe ($index)'
          : '${safe.substring(0, dot)} ($index)${safe.substring(dot)}';
      index++;
      target = _child(candidate);
    }
    _used.add(candidate);
    return target;
  }

  /// 把文件名拼进会话目录，并断言没有逃出去。
  ///
  /// [safeFileName] 已经剥掉了分隔符，这里是第二道闸——将来有人改了净化
  /// 规则、或者从别处传了未经净化的名字进来，也写不到目录外面去。
  File _child(String name) {
    final String root = directory.absolute.path;
    final File file = File('$root${Platform.pathSeparator}$name');
    if (!file.absolute.path.startsWith('$root${Platform.pathSeparator}')) {
      throw StateError('拒绝写入会话目录之外的路径：$name');
    }
    return file;
  }
}

/// 收集 sha256 摘要的小 sink。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
