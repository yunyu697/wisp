import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';
import '../models/device.dart';
import '../models/transfer.dart';
import 'tls_service.dart';

class SendFailure implements Exception {
  SendFailure(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get pinRequired => statusCode == 401;
  bool get rejected => statusCode == 403;
  bool get busy => statusCode == 409;

  @override
  String toString() => message;
}

/// 发送端：握手 → prepare-upload → 逐文件 upload。
class SenderService {
  SenderService({
    required this.alias,
    required this.fingerprint,
    required this.deviceKind,
    required this.port,
    required this.secure,
  });

  final String alias;
  final String fingerprint;
  final String deviceKind;

  /// 本机实际监听端口与协议。必须如实上报：对端拿这两个字段决定
  /// 回连地址（/register 应答、进度回报），写死 53317/https 会让
  /// 改了端口的实例或没证书的实例在对端眼里"连不上"。
  final int port;
  final bool secure;

  /// 连对端用的 HttpClient。
  ///
  /// 局域网里是自签证书，靠**指纹**认人：证书的 SHA-256 必须等于对端在
  /// 报文里声明的 `fingerprint`。以前这里无条件返回 true，等于任何证书都收
  /// ——同网段换一张证书就能中间人劫持。
  ///
  /// [peer] 没带指纹（老版本客户端 / 明文 HTTP）时只能放行，这是协议兼容的
  /// 代价；但只要对端报了指纹，就一定比对。
  HttpClient _client({
    Duration timeout = const Duration(seconds: 12),
    WispDevice? peer,
  }) =>
      HttpClient()
        ..connectionTimeout = timeout
        ..idleTimeout = const Duration(seconds: 15)
        ..badCertificateCallback = (X509Certificate cert, String host, int port) {
          final bool? matches = WispTls.certMatchesClaim(cert, peer?.fingerprint);
          return matches ?? true;
        };

  Map<String, dynamic> get _selfInfo => <String, dynamic>{
        'alias': alias,
        'version': WispProtocol.version,
        'deviceModel': DiscoveryServiceLabel.platform,
        'deviceType': deviceKind,
        'fingerprint': fingerprint,
        'port': port,
        'protocol': secure ? 'https' : 'http',
        'download': false,
      };

  /// 第一步：只发元数据，换回 sessionId 与每个文件的 token。
  Future<void> prepare(TransferSession session, WispDevice device, {String? pin}) async {
    final HttpClient client = _client(peer: device);
    try {
      final Map<String, String> query = <String, String>{
        if (pin != null && pin.isNotEmpty) 'pin': pin,
      };
      final Uri uri = Uri.parse('${device.baseUrl}${WispProtocol.prepareUploadPath}')
          .replace(queryParameters: query.isEmpty ? null : query);
      final HttpClientRequest request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(<String, dynamic>{
        'info': _selfInfo,
        'files': <String, dynamic>{
          for (final TransferFile file in session.files) file.id: file.toProtocolJson(),
        },
      }));

      final HttpClientResponse response = await request.close();
      final String body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 204) {
        session.status = TransferStatus.completed;
        return;
      }
      if (response.statusCode != 200) {
        throw SendFailure(_messageFor(response.statusCode), statusCode: response.statusCode);
      }

      final Map<String, dynamic>? payload = _decode(body);
      if (payload == null) throw SendFailure('对方返回了无法解析的数据');
      final String? sessionId = payload['sessionId'] as String?;
      final Map<String, dynamic>? tokens = payload['files'] as Map<String, dynamic>?;
      if (sessionId == null || tokens == null) throw SendFailure('对方未返回会话信息');

      session.tokens
        ..clear()
        ..addAll(tokens.map((String key, dynamic value) => MapEntry<String, String>(key, value.toString())));
      // 会话号以对端签发的为准，上传/取消都带上它。
      session.remoteSessionId = sessionId;
      session.status = TransferStatus.active;
    } on TlsException {
      // 指纹对不上时 dart:io 抛的就是这个：别让用户只看到一句 Handshake failed。
      throw SendFailure('对端证书与它声明的指纹不一致，已中止连接（可能有人劫持）');
    } finally {
      client.close(force: false);
    }
  }

  /// 第二步：按 token 逐个上传。两路并发，兼顾吞吐和进度平滑度。
  Future<void> uploadAll(
    TransferSession session,
    WispDevice device, {
    void Function()? onProgress,
    bool Function()? isCanceled,
  }) async {
    final HttpClient client = _client(timeout: const Duration(seconds: 30), peer: device);
    try {
      final List<TransferFile> queue = session.files
          .where((TransferFile f) => f.file != null && f.sent < f.size)
          .toList();

      int cursor = 0;
      Future<void> worker() async {
        while (cursor < queue.length) {
          if (isCanceled?.call() ?? false) return;
          final TransferFile file = queue[cursor++];
          await _uploadFile(client, session, device, file, onProgress: onProgress);
        }
      }

      await Future.wait(<Future<void>>[worker(), worker()]);
      if (!(isCanceled?.call() ?? false)) {
        session.status = TransferStatus.completed;
      }
    } on TlsException {
      // 指纹对不上时 dart:io 抛的就是这个：别让用户只看到一句 Handshake failed。
      throw SendFailure('对端证书与它声明的指纹不一致，已中止连接（可能有人劫持）');
    } finally {
      client.close(force: false);
    }
  }

  Future<void> _uploadFile(
    HttpClient client,
    TransferSession session,
    WispDevice device,
    TransferFile file, {
    void Function()? onProgress,
  }) async {
    final String token = session.tokens[file.id] ?? '';
    final Uri uri = Uri.parse('${device.baseUrl}${WispProtocol.uploadPath}').replace(
      queryParameters: <String, String>{
        'sessionId': session.remoteSessionId ?? session.id,
        'fileId': file.id,
        'token': token,
      },
    );

    final HttpClientRequest request = await client.postUrl(uri);
    request.headers.contentType = ContentType.binary;
    request.contentLength = file.size;

    final File source = file.file!;
    final Stream<List<int>> stream = source.openRead();
    await for (final List<int> chunk in stream) {
      request.add(chunk);
      file.sent += chunk.length;
      session.sample();
      onProgress?.call();
    }

    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    if (response.statusCode != 200) {
      throw SendFailure(_messageFor(response.statusCode), statusCode: response.statusCode);
    }
  }

  /// 取消：告知对端释放会话，避免它一直等。
  Future<void> cancel(TransferSession session, WispDevice device) async {
    final HttpClient client = _client(timeout: const Duration(seconds: 5), peer: device);
    try {
      final Uri uri = Uri.parse('${device.baseUrl}${WispProtocol.cancelPath}')
          .replace(queryParameters: <String, String>{
        'sessionId': session.remoteSessionId ?? session.id,
      });
      final HttpClientRequest request = await client.postUrl(uri);
      await request.close();
    } catch (_) {
      // 对端可能已经断开，取消失败无需打扰用户。
    } finally {
      client.close(force: true);
    }
  }

  /// 发送一条文字/剪贴板消息（走官方 LocalSend 的 prepare-upload + preview）。
  ///
  /// 官方语义：正文内联在**恰好一个** `text/plain` 文件的 `preview` 字段里，
  /// 接收端一个文件都不接、回 204，因此不建会话、不落盘。
  ///
  /// * 204 —— 成功（新版本对端，官方语义）；
  /// * 200 —— 旧客户端把消息当普通 .txt 文件接收了。这里**不留 fallback**：
  ///   能解析出 sessionId 就 extra POST 一次 /cancel 清掉僵尸会话（失败静默），
  ///   再抛"请升级到新版本"；
  /// * 403 —— 对方拒收（用户名范围不一致）；
  /// * 413 —— 内容太长。
  ///
  /// [timeMs] 官方消息报文里没有时间字段，接收端以收到时间为准；参数保留是
  /// 为了和调用方（消息模型自带时间戳）保持签名一致，此处刻意不使用。
  Future<void> sendTextMessage(
    WispDevice device, {
    required String id,
    required String text,
    int? timeMs,
  }) async {
    final HttpClient client = _client(peer: device);
    try {
      final Uri uri = Uri.parse('${device.baseUrl}${WispProtocol.prepareUploadPath}');
      final HttpClientRequest request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(<String, dynamic>{
        'info': _selfInfo,
        'files': <String, dynamic>{
          id: <String, dynamic>{
            'id': id,
            'fileName': '$id.txt',
            'size': utf8.encode(text).length,
            'fileType': WispProtocol.textFileType,
            'preview': text,
          },
        },
      }));

      final HttpClientResponse response = await request.close();
      final String body = await response.transform(utf8.decoder).join();
      final int status = response.statusCode;

      // 204：对端认得这是文字消息，一个文件都不接、不建会话、不落盘。
      if (status == 204) return;

      // 200：旧客户端把消息当普通 .txt 文件收了，会留下一个僵尸会话。
      // 不留 fallback：先尽力 cancel 清理，再明确报错让用户升级。
      if (status == 200) {
        final Map<String, dynamic>? payload = _decode(body);
        final String? sessionId = payload?['sessionId'] as String?;
        if (sessionId != null) {
          try {
            final Uri cancelUri =
                Uri.parse('${device.baseUrl}${WispProtocol.cancelPath}')
                    .replace(queryParameters: <String, String>{
              'sessionId': sessionId,
            });
            final HttpClientRequest cancelRequest = await client.postUrl(cancelUri);
            await cancelRequest.close();
          } catch (_) {
            // 清理僵尸会话失败无需打扰用户，静默。
          }
        }
        throw SendFailure('对方不支持文字消息（请升级到新版本）', statusCode: 200);
      }

      // 403 / 413 用消息语境的说法：复用 _messageFor 会得到"对方拒绝了这次
      // 传输""文件校验失败"，放在一条聊天消息上完全对不上。
      if (status == 403) {
        throw SendFailure('对方拒收这条消息（可能用户名不一致）', statusCode: status);
      }
      if (status == 413) {
        throw SendFailure('内容太长，对方拒收', statusCode: status);
      }
      throw SendFailure(_messageFor(status), statusCode: status);
    } on TlsException {
      // 指纹对不上时 dart:io 抛的就是这个：别让用户只看到一句 Handshake failed。
      throw SendFailure('对端证书与它声明的指纹不一致，已中止连接（可能有人劫持）');
    } finally {
      client.close(force: false);
    }
  }

  String _messageFor(int status) {
    switch (status) {
      case 401:
        return '需要 PIN 才能发送';
      case 403:
        return '对方拒绝了这次传输';
      case 409:
        return '对方正在接收其他设备的文件';
      case 413:
        return '内容太长，对方拒收';
      case 422:
        return '文件校验失败，可能传输中损坏';
      case 429:
        return '请求太频繁，稍后再试';
      default:
        return '传输失败（$status）';
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
}

/// 避免 sender 依赖 discovery 的平台判断实现细节。
class DiscoveryServiceLabel {
  const DiscoveryServiceLabel._();

  static String get platform {
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    return 'Unknown';
  }
}
