import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:wisp/core/constants.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/models/message.dart';
import 'package:wisp/services/message_service.dart';
import 'package:wisp/services/receiver_service.dart';
import 'package:wisp/services/sender_service.dart';
import 'package:wisp/services/settings_service.dart';

/// 文本消息链路的单元测试。
///
/// 刻意**不用** `testWidgets`：`flutter_test` 的 binding 会把主 isolate 的
/// HttpClient 整体换成"一律 400"的桩，真实收发就没法测了。这里全程用
/// 普通 `test()`，所以不要在这个文件里引入任何 widget 测试。
WispDevice _deviceFor(int port, {String fingerprint = 'fp-r'}) => WispDevice(
      alias: 'Receiver',
      ip: '127.0.0.1',
      fingerprint: fingerprint,
      port: port,
      https: false,
    );

ReceiverService _receiver({
  required void Function(IncomingMessage) onMessage,
  String username = '',
  bool encryption = false,
}) =>
    ReceiverService(
      settings: WispSettings(
        alias: 'Receiver',
        fingerprint: 'fp-r',
        username: username,
        encryption: encryption,
        port: 0,
      ),
      onIncoming: (IncomingRequest request) async => const ReceiveDecision.reject(),
      onProgress: (_) {},
      onFinished: (_) {},
      onLog: (_) {},
      onMessage: onMessage,
    );

SenderService _sender() => SenderService(
      alias: 'Sender',
      fingerprint: 'fp-s',
      deviceKind: 'desktop',
      port: 53317,
      secure: false,
    );

void main() {
  group('模型', () {
    test('消息 JSON 往返：失败态与错误文案都要留住', () {
      final ChatMessage original = ChatMessage(
        id: 'm1',
        direction: MessageDirection.outgoing,
        text: '第一行\n第二行',
        time: DateTime(2026, 3, 5, 9, 30),
        status: MessageStatus.failed,
        error: '对方不在线',
      );
      final ChatMessage restored = ChatMessage.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(restored.id, 'm1');
      expect(restored.direction, MessageDirection.outgoing);
      expect(restored.text, '第一行\n第二行');
      expect(restored.time, DateTime(2026, 3, 5, 9, 30));
      expect(restored.status, MessageStatus.failed);
      expect(restored.error, '对方不在线');
    });

    test('发送中的消息不落盘，读回来按已发送处理', () {
      final ChatMessage sending = ChatMessage(
        id: 'm2',
        direction: MessageDirection.outgoing,
        text: 'hi',
        time: DateTime(2026, 3, 5),
        status: MessageStatus.sending,
      );
      final Map<String, dynamic> json = sending.toJson();
      expect(json.containsKey('status'), isFalse,
          reason: '发送中重启后必然已经不在飞了，写盘只会留下一个永远转圈的消息');
      expect(ChatMessage.fromJson(json).status, MessageStatus.sent);
    });

    test('乱序到达的消息按时间排好序', () {
      final Conversation conversation =
          Conversation(peerKey: 'k', peerAlias: 'A', peerIp: '1.1.1.1');
      conversation.add(ChatMessage(
        id: 'b',
        direction: MessageDirection.incoming,
        text: '后',
        time: DateTime(2026, 3, 5, 10),
      ));
      conversation.add(ChatMessage(
        id: 'a',
        direction: MessageDirection.outgoing,
        text: '先',
        time: DateTime(2026, 3, 5, 9),
      ));
      expect(conversation.messages.map((ChatMessage m) => m.id), <String>['a', 'b']);
      expect(conversation.preview, '后');
    });

    test('单会话超过上限时只保留最近的消息', () {
      final Conversation conversation =
          Conversation(peerKey: 'k', peerAlias: 'A', peerIp: '1.1.1.1');
      for (int i = 0; i < 10; i++) {
        conversation.add(ChatMessage(
          id: '$i',
          direction: MessageDirection.incoming,
          text: '$i',
          time: DateTime(2026, 3, 5, 9).add(Duration(minutes: i)),
        ));
      }
      conversation.trim(4);
      expect(conversation.messages.map((ChatMessage m) => m.id),
          <String>['6', '7', '8', '9']);
    });

    test('落盘前按最近消息排序并截断会话数', () {
      final List<Conversation> input = <Conversation>[
        for (int i = 0; i < MessageService.conversationLimit + 5; i++)
          Conversation(
            peerKey: 'k$i',
            peerAlias: 'A$i',
            peerIp: '1.1.1.$i',
            messages: <ChatMessage>[
              ChatMessage(
                id: 'm$i',
                direction: MessageDirection.incoming,
                text: 'x',
                time: DateTime(2026, 3, 5).add(Duration(minutes: i)),
              ),
            ],
          ),
      ];
      final List<Conversation> kept = MessageService.normalized(input);
      expect(kept, hasLength(MessageService.conversationLimit));
      expect(kept.first.peerKey, 'k${MessageService.conversationLimit + 4}',
          reason: '最新的会话必须排在最前，否则截断会先丢掉刚聊过的那条');
    });

    test('设备能力位：对端声明 message 才认', () {
      expect(
        WispDevice.fromJson(<String, dynamic>{'alias': 'A', 'message': true}, ip: '1.1.1.1')
            .messageCapable,
        isTrue,
      );
      // 官方 LocalSend 的报文里没有这个字段。
      expect(
        WispDevice.fromJson(<String, dynamic>{'alias': 'A'}, ip: '1.1.1.1').messageCapable,
        isFalse,
      );
    });
  });

  group('端点', () {
    test('文本消息直达状态层，不建传输会话、不写文件', () async {
      final List<IncomingMessage> received = <IncomingMessage>[];
      final ReceiverService receiver = _receiver(onMessage: received.add);
      await receiver.start();
      addTearDown(receiver.dispose);

      await _sender().sendMessage(
        _deviceFor(receiver.boundPort!),
        id: 'm-1',
        text: '你好，世界',
        timeMs: DateTime(2026, 3, 5, 9, 30).millisecondsSinceEpoch,
      );

      expect(received, hasLength(1));
      expect(received.single.text, '你好，世界');
      expect(received.single.sender.alias, 'Sender');
      expect(received.single.time, DateTime(2026, 3, 5, 9, 30));
    });

    test('用户名范围不一致直接拒收', () async {
      final List<IncomingMessage> received = <IncomingMessage>[];
      final ReceiverService receiver =
          _receiver(onMessage: received.add, username: 'alice');
      await receiver.start();
      addTearDown(receiver.dispose);

      await expectLater(
        _sender().sendMessage(_deviceFor(receiver.boundPort!), id: 'm-2', text: 'hi'),
        throwsA(isA<SendFailure>()
            .having((SendFailure e) => e.statusCode, 'statusCode', 403)),
      );
      expect(received, isEmpty);
    });

    test('文本超过上限时 413，不会把超大 body 读进内存', () async {
      final List<IncomingMessage> received = <IncomingMessage>[];
      final ReceiverService receiver = _receiver(onMessage: received.add);
      await receiver.start();
      addTearDown(receiver.dispose);

      final String tooLong = 'x' * (WispProtocol.maxMessageChars + 1);
      await expectLater(
        _sender().sendMessage(_deviceFor(receiver.boundPort!), id: 'm-3', text: tooLong),
        throwsA(isA<SendFailure>()
            .having((SendFailure e) => e.statusCode, 'statusCode', 413)),
      );
      expect(received, isEmpty);
    });

    test('对端没有这个端点时给出「只能收发文件」的提示', () async {
      final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((HttpRequest request) async {
        await request.drain<void>();
        request.response.statusCode = 404;
        await request.response.close();
      });

      await expectLater(
        _sender().sendMessage(_deviceFor(server.port), id: 'm-4', text: 'hi'),
        throwsA(isA<SendFailure>().having(
          (SendFailure e) => e.message,
          'message',
          contains('只能收发文件'),
        )),
      );
    });
  });
}
