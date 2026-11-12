import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:wisp/core/constants.dart';
import 'package:wisp/models/message.dart';
import 'package:wisp/models/transfer.dart';
import 'package:wisp/services/receiver_service.dart';
import 'package:wisp/services/settings_service.dart';

/// 官方 LocalSend preview 文字消息通道的护栏测试。
///
/// 同样只用普通 `test()`：真实 HttpServer + 真实 ReceiverService，
/// 不引入任何 `testWidgets`（那会把 HttpClient 换成一律 400 的桩）。
Map<String, dynamic> _textFile(String id, String text) => <String, dynamic>{
      'id': id,
      'fileName': '$id.txt',
      'size': utf8.encode(text).length,
      'fileType': WispProtocol.textFileType,
      'preview': text,
    };

Map<String, dynamic> _binaryFile(String id) => <String, dynamic>{
      'id': id,
      'fileName': 'photo.bin',
      'size': 1024,
      'fileType': 'application/octet-stream',
    };

class _Harness {
  _Harness({
    this.decision = const ReceiveDecision.reject(),
    WispSettings? settings,
  }) : settings = settings ??
            const WispSettings(
              alias: 'Receiver',
              fingerprint: 'fp-r',
              port: 0,
              encryption: false,
            );

  final ReceiveDecision decision;
  final WispSettings settings;
  final List<IncomingMessage> messages = <IncomingMessage>[];
  int incomingCalls = 0;
  int finishedCalls = 0;

  late final ReceiverService receiver = ReceiverService(
    settings: settings,
    onIncoming: (IncomingRequest request) async {
      incomingCalls++;
      return decision;
    },
    onProgress: (_) {},
    onFinished: (_) {
      finishedCalls++;
    },
    onLog: (_) {},
    onMessage: messages.add,
  );

  Future<void> start() => receiver.start();
  int get port => receiver.boundPort!;
  Future<void> dispose() => receiver.dispose();
}

/// 直接向 prepare-upload POST 一段协议报文，返回状态码。
Future<int> _postPrepare(
  int port,
  Map<String, dynamic> files, {
  Map<String, dynamic>? info,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port${WispProtocol.prepareUploadPath}'),
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(<String, dynamic>{
      'info': info ??
          <String, dynamic>{
            'alias': 'Sender',
            'fingerprint': 'fp-s',
            'version': WispProtocol.version,
          },
      'files': files,
    }));
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<_Harness> _start(_Harness harness) async {
  await harness.start();
  addTearDown(harness.dispose);
  return harness;
}

void main() {
  group('TransferFile 的 preview', () {
    test('toProtocolJson / fromProtocolJson 往返保留 preview', () {
      final TransferFile file = TransferFile(
        id: 'f1',
        name: 'f1.txt',
        size: 6,
        mime: WispProtocol.textFileType,
        preview: '你好世界',
      );
      final Map<String, dynamic> json = file.toProtocolJson();
      expect(json['fileType'], 'text/plain');
      expect(json['preview'], '你好世界');

      final TransferFile back = TransferFile.fromProtocolJson('f1', json);
      expect(back.id, 'f1');
      expect(back.mime, WispProtocol.textFileType);
      expect(back.preview, '你好世界');
    });

    test('普通文件不写 preview，读回来为 null', () {
      final TransferFile plain = TransferFile(
        id: 'f2',
        name: 'a.bin',
        size: 1,
      );
      expect(plain.toProtocolJson().containsKey('preview'), isFalse);
      expect(
        TransferFile.fromProtocolJson('f2', plain.toProtocolJson()).preview,
        isNull,
      );
    });
  });

  group('恰好 1 个 text 文件才走消息', () {
    test('单个 text/plain + preview：回 204，直接进会话，不询问不建会话', () async {
      final _Harness harness = await _start(_Harness());
      final int status = await _postPrepare(
        harness.port,
        <String, dynamic>{'m1': _textFile('m1', '你好')},
      );

      expect(status, 204,
          reason: '官方语义：一个文件都不接、回 204，因此不落盘');
      expect(harness.messages, hasLength(1));
      expect(harness.messages.single.text, '你好');
      expect(harness.messages.single.id, 'm1');
      expect(harness.incomingCalls, 0, reason: '文字消息不经过确认弹层');
      expect(harness.finishedCalls, 0, reason: '文字消息不建传输会话');
    });

    test('text/plain 但没有 preview：当成普通文件，不是消息', () async {
      final _Harness harness = await _start(_Harness());
      final Map<String, dynamic> noPreview = <String, dynamic>{
        'id': 'f1',
        'fileName': 'f1.txt',
        'size': 3,
        'fileType': WispProtocol.textFileType,
      };
      final int status = await _postPrepare(
        harness.port,
        <String, dynamic>{'f1': noPreview},
      );

      expect(harness.messages, isEmpty);
      expect(harness.incomingCalls, 1, reason: '要走正常的接收确认流程');
      expect(status, 403, reason: 'harness 默认 resolve(reject)');
    });

    test('两个 text 文件（哪怕都有 preview）也不算消息', () async {
      final _Harness harness = await _start(_Harness());
      final int status = await _postPrepare(
        harness.port,
        <String, dynamic>{
          'a': _textFile('a', 'A'),
          'b': _textFile('b', 'B'),
        },
      );

      expect(harness.messages, isEmpty,
          reason: '必须恰好 1 个 text/plain 文件');
      expect(harness.incomingCalls, 1);
      expect(status, 403);
    });

    test('空 preview 文本回 400，不进会话', () async {
      final _Harness harness = await _start(_Harness());
      final int status = await _postPrepare(
        harness.port,
        <String, dynamic>{'m': _textFile('m', '   ')},
      );
      expect(status, 400);
      expect(harness.messages, isEmpty);
    });
  });

  group('204 语义', () {
    test('空文件清单：回 204（Finished, no file transfer needed）', () async {
      final _Harness harness = await _start(_Harness());
      final int status = await _postPrepare(
        harness.port,
        <String, dynamic>{},
      );
      expect(status, 204);
      expect(harness.messages, isEmpty);
      expect(harness.incomingCalls, 0);
      expect(harness.finishedCalls, 0);
    });

    test('用户一个文件都不选：空 accept 回 204，而不是 403', () async {
      final _Harness harness = await _start(
        _Harness(decision: const ReceiveDecision.accept(fileIds: <String>{})),
      );
      final int status = await _postPrepare(
        harness.port,
        <String, dynamic>{'f1': _binaryFile('f1')},
      );
      expect(status, 204, reason: '官方空 accept 就是 204，不是"拒绝"');
      expect(harness.incomingCalls, 1);
      expect(harness.finishedCalls, 0, reason: '空 accept 不建会话');
    });
  });

  group('安全边界', () {
    test('PIN 仍生效：即便策略是 all，缺 PIN 的文件请求照样 401', () async {
      final _Harness harness = await _start(_Harness(
        settings: WispSettings(
          alias: 'Receiver',
          fingerprint: 'fp-r',
          port: 0,
          encryption: false,
          pinEnabled: true,
          pin: '1234',
          receivePolicy: ReceivePolicy.all,
        ),
      ));
      final int status = await _postPrepare(
        harness.port,
        <String, dynamic>{'f1': _binaryFile('f1')},
      );
      expect(status, 401,
          reason: 'PIN 校验在 shouldAutoAccept 之前，自动接收不绕过 PIN');
      expect(harness.incomingCalls, 0);
      expect(harness.finishedCalls, 0);
    });

    test('用户名范围不一致：即便策略是 all 也 403，且不是文字消息', () async {
      final _Harness harness = await _start(_Harness(
        settings: WispSettings(
          alias: 'Receiver',
          fingerprint: 'fp-r',
          port: 0,
          encryption: false,
          username: 'alice',
          receivePolicy: ReceivePolicy.all,
          trustedFingerprints: <String>['fp-s'],
        ),
      ));
      final int status = await _postPrepare(
        harness.port,
        <String, dynamic>{'m1': _textFile('m1', '你好')},
      );
      expect(status, 403);
      expect(harness.messages, isEmpty);
      expect(harness.incomingCalls, 0);
    });
  });
}
