// 证书指纹绑定：对端出示的证书必须与它声明的 fingerprint 一致。
//
// 以前所有 HttpClient 都写着 `badCertificateCallback => true`，等于任何证书
// 都能握手成功——同网段换张证书就能中间人劫持，加密只防了旁观者。
// 这组用例把「证书 ≠ 声明指纹时必须失败」钉死。
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/models/transfer.dart';
import 'package:wisp/services/receiver_service.dart';
import 'package:wisp/services/sender_service.dart';
import 'package:wisp/services/settings_service.dart';
import 'package:wisp/services/tls_service.dart';

class _Attempt {
  const _Attempt({
    required this.port,
    required this.filePath,
    required this.size,
    required this.peerFingerprint,
  });

  final int port;
  final String filePath;
  final int size;

  /// 发送端「以为」对端的指纹。故意填错时握手必须被拒。
  final String peerFingerprint;
}

/// 发送端放独立 isolate：主 isolate 的 HttpClient 被 flutter_test 换成了桩。
Future<String?> _send(_Attempt a) {
  return Isolate.run(() async {
    final SenderService sender = SenderService(
      alias: 'Pinner',
      fingerprint: 'pinner-fp',
      deviceKind: 'desktop',
      port: a.port,
      secure: true,
    );
    final WispDevice peer = WispDevice(
      alias: 'Pinned',
      ip: '127.0.0.1',
      fingerprint: a.peerFingerprint,
      port: a.port,
      https: true,
    );
    final TransferSession session = TransferSession(
      id: 'pin-1',
      peerAlias: peer.alias,
      peerIp: peer.ip,
      direction: TransferDirection.outgoing,
      files: <TransferFile>[
        TransferFile(id: 'f1', name: 'pin.bin', size: a.size, path: a.filePath),
      ],
    );
    try {
      await sender.prepare(session, peer).timeout(const Duration(seconds: 20));
      await sender.uploadAll(session, peer).timeout(const Duration(seconds: 30));
      return null;
    } catch (e) {
      return '$e';
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('指纹归一化', () {
    test('冒号、空格、大小写都不影响比较', () {
      expect(WispTls.normalizeFingerprint('AA:BB:CC'), 'aabbcc');
      expect(WispTls.normalizeFingerprint(' aa bb '), 'aabb');
      expect(WispTls.normalizeFingerprint('AaBbCc'), 'aabbcc');
      expect(WispTls.normalizeFingerprint(''), '');
    });

    test('没有证书或没有声明指纹时返回 null，而不是"通过"', () {
      expect(WispTls.certMatchesClaim(null, 'aabb'), isNull);
      expect(WispTls.certMatchesClaim(null, null), isNull);
    });
  });

  test('指纹对不上时握手必须被拒绝，对得上时正常传完', () async {
    final String? own = await WispTls.fingerprint();
    expect(own, isNotNull, reason: '缺少内置证书，先跑 tools/gen_cert.sh');

    final Directory dir = await Directory.systemTemp.createTemp('wisp-pin');
    addTearDown(() => dir.delete(recursive: true));
    final String sep = Platform.pathSeparator;
    final File payload = File('${dir.path}${sep}pin.bin');
    final List<int> bytes = List<int>.generate(32 * 1024, (int i) => i % 253);
    await payload.writeAsBytes(bytes);

    final List<TransferSession> received = <TransferSession>[];
    final List<String> logs = <String>[];
    final ReceiverService receiver = ReceiverService(
      settings: WispSettings(
        alias: 'Pinned',
        fingerprint: 'pinned-fp',
        encryption: true,
        saveDirectory: dir.path,
        port: 0,
      ),
      onIncoming: (IncomingRequest request) async => const ReceiveDecision.accept(),
      onProgress: (TransferSession session) {},
      onFinished: (TransferSession session) => received.add(session),
      onLog: (String message) => logs.add(message),
    );
    await receiver.start();
    addTearDown(receiver.stop);
    expect(receiver.isSecure, isTrue, reason: '接收端应启用 TLS');

    // 1) 指纹错误（全 0 的 64 位十六进制）：握手阶段就该断，接收端连日志都收不到。
    final String? bad = await _send(_Attempt(
      port: receiver.boundPort!,
      filePath: payload.path,
      size: bytes.length,
      peerFingerprint: '0' * 64,
    ));
    expect(bad, isNotNull, reason: '指纹不符竟然传成功了，说明根本没校验');
    expect(bad, contains('指纹'), reason: '错误提示应说明是证书/指纹问题：$bad');
    expect(received, isEmpty, reason: '握手被拒时不应产生任何接收会话');

    // 2) 指纹正确（用带冒号的大写形式，顺带验证归一化）：正常传完。
    final String? ok = await _send(_Attempt(
      port: receiver.boundPort!,
      filePath: payload.path,
      size: bytes.length,
      peerFingerprint: own!,
    ));
    expect(ok, isNull, reason: '指纹一致却失败：$ok\n接收端日志：\n${logs.join('\n')}');

    for (int i = 0; i < 50 && received.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(received, hasLength(1));
    expect(received.first.status, TransferStatus.completed);
    final File saved = File('${dir.path}${sep}pin.bin');
    expect(await saved.exists(), isTrue);
    expect((await saved.readAsBytes()).length, bytes.length);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
