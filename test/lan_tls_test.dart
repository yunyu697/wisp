// 端到端回归：ReceiverService（HTTPS 自签证书）+ SenderService 走真实 TCP。
//
// 与 selftest 的 send_loopback 不同，这里接收端用的是真 ReceiverService
// （含证书加载、bindSecure、token 校验、落盘），覆盖「证书 → TLS →
// prepare → upload → sha256 校验」整条链。
//
// 发送端放在独立 isolate 里跑：flutter_test 的绑定会把主 isolate 的
// HttpClient 换成假桩（一律回 400），纯 dart:io 的 SenderService 不该
// 被它拦住。SenderService 本身只依赖 dart:io，可以安全地搬进 isolate。
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/models/transfer.dart';
import 'package:wisp/models/message.dart';
import 'package:wisp/services/receiver_service.dart';
import 'package:wisp/services/sender_service.dart';
import 'package:wisp/services/settings_service.dart';

/// 在无绑定的 isolate 里跑发送端，返回错误信息；成功返回 null。
Future<String?> _sendFromIsolate(_SendTask task) {
  return Isolate.run(() async {
    final SenderService sender = SenderService(
      alias: task.senderAlias,
      fingerprint: 'test-sender-fp',
      deviceKind: 'desktop',
      port: task.port,
      secure: false,
    );
    final WispDevice peer = WispDevice(
      alias: 'TestReceiver',
      ip: '127.0.0.1',
      fingerprint: '',
      port: task.port,
      https: true,
    );
    final TransferSession session = TransferSession(
      id: 'lan-tls-1',
      peerAlias: peer.alias,
      peerIp: peer.ip,
      direction: TransferDirection.outgoing,
      files: <TransferFile>[
        TransferFile(
            id: 'f1',
            name: 'probe.bin',
            size: task.bytes.length,
            path: task.filePath),
      ],
    );
    try {
      await sender
          .prepare(session, peer)
          .timeout(const Duration(seconds: 20));
      if (session.status != TransferStatus.active) {
        return 'prepare 后状态是 ${session.status.name}';
      }
      if (session.tokens['f1'] == null) return 'prepare 未换回 token';
      await sender
          .uploadAll(session, peer)
          .timeout(const Duration(seconds: 30));
      if (session.status != TransferStatus.completed) {
        return 'upload 后状态是 ${session.status.name}';
      }
      return null;
    } catch (e) {
      return '$e';
    }
  });
}

/// isolate 之间不能直接传 File，打包成纯数据。
class _SendTask {
  _SendTask({
    required this.port,
    required this.filePath,
    required this.bytes,
    required this.senderAlias,
  });

  final int port;
  final String filePath;
  final List<int> bytes;
  final String senderAlias;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HTTPS 全链路：自签证书收发一致', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('wisp-lan-test');
    addTearDown(() => dir.delete(recursive: true));

    final File payload = File('${dir.path}${Platform.pathSeparator}probe.bin');
    final List<int> bytes =
        List<int>.generate(192 * 1024, (int i) => (i * 7) % 251);
    await payload.writeAsBytes(bytes);

    final List<TransferSession> received = <TransferSession>[];
    final List<String> logs = <String>[];
    final ReceiverService receiver = ReceiverService(
      settings: WispSettings(
        alias: 'TestReceiver',
        fingerprint: 'test-receiver-fp',
        encryption: true,
        // 测试环境的 path_provider 是个桩，直接指定落盘目录。
        saveDirectory: dir.path,
        // 端口 0：让操作系统挑一个空闲端口，测试里不抢 53317。
        port: 0,
      ),
      onIncoming: (IncomingRequest request) async =>
          const ReceiveDecision.accept(),
      onProgress: (TransferSession session) {},
      onFinished: (TransferSession session) => received.add(session),
      onLog: (String message) => logs.add(message),
      onMessage: (IncomingMessage message) {},
    );
    await receiver.start();
    addTearDown(receiver.stop);
    expect(receiver.isSecure, isTrue,
        reason: '内置证书应当启用 TLS（logs: ${logs.join(' | ')}）');
    expect(receiver.boundPort, isNotNull);

    final String? sendError = await _sendFromIsolate(_SendTask(
      port: receiver.boundPort!,
      filePath: payload.path,
      bytes: bytes,
      senderAlias: 'TestSender',
    ));
    expect(sendError, isNull,
        reason: '发送端报错：$sendError\n接收端日志：\n${logs.join('\n')}');

    // 轮询等接收端回报完成，最多 10 秒。
    for (int i = 0; i < 50 && received.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(received, hasLength(1), reason: '接收端应回报 onFinished');
    expect(received.first.status, TransferStatus.completed,
        reason: logs.join('\n'));

    // 接收侧的 TransferFile 不带绝对路径，落盘位置在会话的 saveDir 下。
    final File savedFile =
        File('${received.first.saveDir}${Platform.pathSeparator}probe.bin');
    expect(await savedFile.exists(), isTrue,
        reason: '文件应落在 ${received.first.saveDir}');
    final List<int> saved = await savedFile.readAsBytes();
    expect(saved.length, bytes.length);
    bool identical = true;
    for (int i = 0; i < bytes.length; i++) {
      if (saved[i] != bytes[i]) {
        identical = false;
        break;
      }
    }
    expect(identical, isTrue, reason: '逐字节一致');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
