// 端到端回归：对端用穿越型文件名发包，落盘必须仍然留在会话目录内。
//
// 这不是纯函数测试——它真的起 ReceiverService、真的走 TCP、真的落盘。
// 修复前这条用例会成功把文件写到 saveDir 的三层父目录，也就是
// 「任何同网段设备都能往任意可写位置丢文件」，自动接收时用户无感。
//
// 发送端必须放独立 isolate：flutter_test 的绑定会把主 isolate 的
// HttpClient 换成一概 400 的假桩（与 lan_tls_test 同一个坑）。
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/models/transfer.dart';
import 'package:wisp/services/receiver_service.dart';
import 'package:wisp/services/sender_service.dart';
import 'package:wisp/services/settings_service.dart';

class _NastyFile {
  const _NastyFile({required this.id, required this.name, required this.path});

  final String id;

  /// 对端在 prepare-upload 里自报的 `fileName`——完全不可信。
  final String name;
  final String path;
}

class _NastyTask {
  const _NastyTask({required this.port, required this.files});

  final int port;
  final List<_NastyFile> files;
}

/// 在无绑定的 isolate 里跑发送端；成功返回 null，失败返回错误信息。
Future<String?> _sendNasty(_NastyTask task) {
  return Isolate.run(() async {
    final SenderService sender = SenderService(
      alias: 'NastySender',
      fingerprint: 'nasty-fp',
      deviceKind: 'desktop',
      port: task.port,
      secure: false,
    );
    final WispDevice peer = WispDevice(
      alias: 'Victim',
      ip: '127.0.0.1',
      fingerprint: '',
      port: task.port,
      https: false,
    );
    final TransferSession session = TransferSession(
      id: 'traversal-1',
      peerAlias: peer.alias,
      peerIp: peer.ip,
      direction: TransferDirection.outgoing,
      files: <TransferFile>[
        for (final _NastyFile f in task.files)
          TransferFile(
            id: f.id,
            name: f.name,
            size: File(f.path).lengthSync(),
            path: f.path,
          ),
      ],
    );
    try {
      await sender.prepare(session, peer).timeout(const Duration(seconds: 20));
      if (session.status != TransferStatus.active) {
        return 'prepare 后状态是 ${session.status.name}';
      }
      await sender.uploadAll(session, peer).timeout(const Duration(seconds: 30));
      return null;
    } catch (e) {
      return '$e';
    }
  });
}

void main() {
  test('穿越型文件名只能落在会话目录内', () async {
    final Directory root = await Directory.systemTemp.createTemp('wisp-escape');
    addTearDown(() => root.delete(recursive: true));

    // 会话目录埋在三层里：任何一层「少剥一段」都会把文件丢到 root 或更上层。
    final Directory saveDir =
        await Directory('${root.path}/a/b/inbox').create(recursive: true);
    final String sep = Platform.pathSeparator;
    final String up3 = '..$sep..$sep..$sep';

    // 发送端的源文件放在 root 下，与落盘目录无关。
    final File payload = File('${root.path}${sep}payload.bin');
    await payload.writeAsBytes(List<int>.generate(4096, (int i) => i % 256));

    final List<String> logs = <String>[];
    final List<TransferSession> received = <TransferSession>[];
    final ReceiverService receiver = ReceiverService(
      settings: WispSettings(
        alias: 'Victim',
        fingerprint: 'victim-fp',
        encryption: false,
        saveDirectory: saveDir.path,
        port: 0,
      ),
      onIncoming: (IncomingRequest request) async =>
          const ReceiveDecision.accept(),
      onProgress: (TransferSession session) {},
      onFinished: (TransferSession session) => received.add(session),
      onLog: (String message) => logs.add(message),
    );
    await receiver.start();
    addTearDown(receiver.stop);

    final String? sendError = await _sendNasty(_NastyTask(
      port: receiver.boundPort!,
      files: <_NastyFile>[
        _NastyFile(
          id: 'f1',
          // 三层上跳：修复前会落到 root/escaped.txt
          name: '${up3}escaped.txt',
          path: payload.path,
        ),
        _NastyFile(
          id: 'f2',
          // 混写分隔符，且中间再嵌一层目录（修复前会落到 root/inner/also.txt）
          name: '..$sep..$sep..${sep}inner${sep}also.txt',
          path: payload.path,
        ),
      ],
    ));
    expect(sendError, isNull,
        reason: '发送端报错：$sendError\n接收端日志：\n${logs.join('\n')}');

    for (int i = 0; i < 50 && received.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(received, hasLength(1), reason: '接收端应回报 onFinished');
    expect(received.first.status, TransferStatus.completed,
        reason: logs.join('\n'));

    // 1) 名字被收成纯文件名，落在会话目录里。
    for (final String name in <String>['escaped.txt', 'also.txt']) {
      final File inside = File('${saveDir.path}$sep$name');
      expect(await inside.exists(), isTrue,
          reason: '$name 应当落在 ${saveDir.path}，实际日志：\n${logs.join('\n')}');
    }

    // 2) 会话目录外面一个都不能有。
    final List<String> outside = <String>[
      '${root.path}${sep}escaped.txt',
      '${root.path}${sep}also.txt',
      '${root.path}${sep}a${sep}escaped.txt',
      '${root.path}${sep}a${sep}b${sep}escaped.txt',
      '${root.path}${sep}a${sep}also.txt',
      '${root.path}${sep}a${sep}b${sep}also.txt',
      '${root.path}${sep}inner${sep}also.txt',
    ];
    for (final String path in outside) {
      expect(await File(path).exists(), isFalse, reason: '文件逃出了会话目录：$path');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
