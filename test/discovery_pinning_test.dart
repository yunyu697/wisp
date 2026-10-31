// 证书指纹比对的「误报」回归。
//
// 协议 §2 规定：HTTPS 模式下 `fingerprint` 是证书的 SHA-256，HTTP 模式下是
// 随机串。Wisp 一直上报 32 位随机串（历史实现），1.0.20 拿它去比 64 位证书
// 哈希，结果每台真实设备都被判成「证书与声明不符」：设备从列表里消失，
// 横幅每隔几秒刷一条同样的提示。
//
// 这组用例钉两件事：
// 1. 非证书形状的声明（32 位随机串）不算不一致，设备照常被发现；
// 2. 真的报了证书哈希却对不上时，仍然拒绝，而且**同一台设备只提示一次**。
//
// 注意：`flutter_test` 会把主 isolate 的 HttpClient 整体换成桩（一律 400），
// 所以真正发请求的部分必须放进 Isolate.run；TLS 服务端留在主 isolate
// （它要读 assets 里的证书）。
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/services/discovery_service.dart';
import 'package:wisp/services/settings_service.dart';
import 'package:wisp/services/tls_service.dart';

/// 起一台假对端：HTTPS，`/register` 回一份带指定指纹的设备信息。
Future<HttpServer> _startPeer(String fingerprint) async {
  final SecurityContext? context = await WispTls.context();
  expect(context, isNotNull, reason: '缺少内置证书，先跑 tools/gen_cert.sh');
  final HttpServer server =
      await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context!);
  server.listen((HttpRequest request) async {
    await request.drain<void>();
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(<String, dynamic>{
      'alias': 'FakePeer',
      'version': '2.2',
      'deviceModel': 'test',
      'deviceType': 'desktop',
      'fingerprint': fingerprint,
      'port': server.port,
      'protocol': 'https',
      'download': false,
    }));
    await request.response.close();
  });
  return server;
}

class _ProbeResult {
  const _ProbeResult(this.aliases, this.errors);

  final List<String> aliases;
  final List<String> errors;
}

/// 在独立 isolate 里对 [ip] 连续探测 [rounds] 次。
Future<_ProbeResult> _probe(String ip, int port, int rounds) {
  return Isolate.run(() async {
    final List<String> aliases = <String>[];
    final List<String> errors = <String>[];
    final DiscoveryService discovery = DiscoveryService(
      settings: WispSettings(
        alias: 'Probe',
        fingerprint: 'self-fp',
        port: port,
      ),
      onDevice: (device) => aliases.add(device.alias),
      onError: errors.add,
      secure: true,
    );
    for (int i = 0; i < rounds; i++) {
      await discovery.probeAddress(ip);
    }
    await discovery.dispose();
    return _ProbeResult(aliases, errors);
  });
}

/// 在独立 isolate 里握手取证书，返回各项判定结果。
///
/// 必须是**顶层函数**：闭包会把外层作用域整个塞进 isolate 消息，
/// 里面的 HttpServer 不可发送，会直接报 Illegal argument。
Future<Map<String, bool?>> _handshakeVerdicts(int port, String claim) {
  return Isolate.run(() async {
    final HttpClient client = HttpClient()
      ..badCertificateCallback = (X509Certificate cert, String host, int p) => true;
    try {
      final HttpClientRequest request =
          await client.getUrl(Uri.parse('https://127.0.0.1:$port/'));
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      final X509Certificate? cert = response.certificate;
      return <String, bool?>{
        'hasCert': cert != null,
        // 真实指纹（带冒号大写）能对上，说明归一化与计算口径一致。
        'own': WispTls.certMatchesClaim(cert, claim),
        // 形状正确但内容错误 → 明确判定为不一致。
        'wrong': WispTls.certMatchesClaim(cert, '0' * 64),
        // 设备 ID / 空串 / 非十六进制 → 无法判定，交给调用方放行。
        'deviceId': WispTls.certMatchesClaim(cert, 'a1b2c3d4e5f60718293a4b5c6d7e8f90'),
        'empty': WispTls.certMatchesClaim(cert, ''),
        'garbage': WispTls.certMatchesClaim(cert, 'not-a-hash'),
      };
    } finally {
      client.close(force: true);
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('对端报的是 32 位设备 ID（Wisp 现状）时，不应判成证书不一致', () async {
    // Wisp 的 settings.fingerprint 就是 16 字节随机数的十六进制，共 32 位。
    const String deviceId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
    expect(deviceId.length, 32);

    final HttpServer peer = await _startPeer(deviceId);
    addTearDown(() => peer.close(force: true));

    final _ProbeResult result = await _probe('127.0.0.1', peer.port, 1);

    expect(result.errors, isEmpty,
        reason: '32 位设备 ID 不是证书指纹，不该触发「证书与声明不符」：${result.errors}');
    expect(result.aliases, <String>['FakePeer'], reason: '设备应当照常被发现，而不是被丢掉');
  });

  test('对端报了证书哈希但对不上时拒绝，且同一地址只提示一次', () async {
    // 形状正确（64 位十六进制）、内容错误：这才是真正的冒充特征。
    final String wrongHash = 'f' * 64;
    final HttpServer peer = await _startPeer(wrongHash);
    addTearDown(() => peer.close(force: true));

    // 扫描每 30 秒一轮，同一台设备会反复撞上——连探三次，提示只能有一条。
    final _ProbeResult result = await _probe('127.0.0.1', peer.port, 3);

    expect(result.aliases, isEmpty, reason: '证书与声明不符时不能把对方当成可信设备');
    expect(result.errors, hasLength(1),
        reason: '三次探测应当只提示一次：${result.errors}');
  });

  test('证书指纹形状的判定：32 位设备 ID 与 64 位哈希分开对待', () async {
    final String? own = await WispTls.fingerprint();
    expect(own, isNotNull);
    expect(WispTls.normalizeFingerprint(own!).length, 64);

    final HttpServer peer = await _startPeer(own);
    addTearDown(() => peer.close(force: true));

    // 握手与比对都放进 isolate：那里才有真的 HttpClient。
    final Map<String, bool?> verdicts = await _handshakeVerdicts(peer.port, own);

    expect(verdicts['hasCert'], isTrue, reason: 'HTTPS 握手后应能拿到对端证书');
    expect(verdicts['own'], isTrue);
    expect(verdicts['wrong'], isFalse);
    expect(verdicts['deviceId'], isNull);
    expect(verdicts['empty'], isNull);
    expect(verdicts['garbage'], isNull);
    expect(WispTls.certMatchesClaim(null, own), isNull, reason: '没有证书时不能判定');
  });
}
