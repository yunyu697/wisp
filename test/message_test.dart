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

    test('Conversation.trim 不再删消息（超出上限只归档）', () {
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
      // 记录全量保留，只是不再有"截断"效果。
      expect(conversation.messages.map((ChatMessage m) => m.id),
          <String>['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']);
    });

    test('normalized 按最近消息排序，但不再删任何记录', () {
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
      expect(kept, hasLength(MessageService.conversationLimit + 5),
          reason: '超出建议展示数量的会话只归档、不删除');
      expect(kept.first.peerKey, 'k${MessageService.conversationLimit + 4}',
          reason: '仍按最近一条消息倒序');
      expect(kept.last.peerKey, 'k0');
      // 单会话消息也一条不删。
      for (final Conversation conversation in kept) {
        expect(conversation.messages, hasLength(1));
      }
    });

    test('对端报文里遗留的 message 能力位被忽略（门控已退役）', () {
      final WispDevice device = WispDevice.fromJson(
        <String, dynamic>{
          'alias': 'A',
          'message': true,
          'fingerprint': 'fp',
        },
        ip: '1.1.1.1',
      );
      expect(device.alias, 'A');
      expect(device.toJson().containsKey('message'), isFalse,
          reason: '私有能力位已退役，既不写出去也不再读取为门控');
    });
  });

  group('官方 preview 文字消息通道', () {
    test('sendTextMessage：preview 内联，回 204、不询问、不建会话', () async {
      final List<IncomingMessage> received = <IncomingMessage>[];
      int incomingCalls = 0;
      int finishedCalls = 0;
      final ReceiverService receiver = ReceiverService(
        settings: WispSettings(
          alias: 'Receiver',
          fingerprint: 'fp-r',
          port: 0,
          encryption: false,
        ),
        onIncoming: (IncomingRequest request) async {
          incomingCalls++;
          return const ReceiveDecision.reject();
        },
        onProgress: (_) {},
        onFinished: (_) {
          finishedCalls++;
        },
        onLog: (_) {},
        onMessage: received.add,
      );
      await receiver.start();
      addTearDown(receiver.dispose);

      await _sender().sendTextMessage(
        _deviceFor(receiver.boundPort!),
        id: 'm-1',
        text: '你好，世界',
        timeMs: DateTime(2026, 3, 5, 9, 30).millisecondsSinceEpoch,
      );

      expect(received, hasLength(1));
      expect(received.single.id, 'm-1');
      expect(received.single.text, '你好，世界');
      expect(received.single.sender.alias, 'Sender');
      // 官方消息报文没有时间字段，接收端以收到时间为准，不采用 timeMs。
      expect(received.single.time, isNot(DateTime(2026, 3, 5, 9, 30)));
      expect(incomingCalls, 0, reason: '文字消息不经过"接受/拒绝"确认');
      expect(finishedCalls, 0, reason: '文字消息不建传输会话、不落盘');
    });

    test('用户名范围不一致：403 并给出消息语境的文案', () async {
      final List<IncomingMessage> received = <IncomingMessage>[];
      final ReceiverService receiver =
          _receiver(onMessage: received.add, username: 'alice');
      await receiver.start();
      addTearDown(receiver.dispose);

      await expectLater(
        _sender().sendTextMessage(
          _deviceFor(receiver.boundPort!),
          id: 'm-2',
          text: 'hi',
        ),
        throwsA(isA<SendFailure>()
            .having((SendFailure e) => e.statusCode, 'statusCode', 403)
            .having((SendFailure e) => e.message, 'message',
                contains('拒收这条消息'))),
      );
      expect(received, isEmpty);
    });

    test('文本超过上限：413，不把消息交给状态层', () async {
      final List<IncomingMessage> received = <IncomingMessage>[];
      final ReceiverService receiver = _receiver(onMessage: received.add);
      await receiver.start();
      addTearDown(receiver.dispose);

      final String tooLong = 'x' * (WispProtocol.maxMessageChars + 1);
      await expectLater(
        _sender().sendTextMessage(
          _deviceFor(receiver.boundPort!),
          id: 'm-3',
          text: tooLong,
        ),
        throwsA(isA<SendFailure>()
            .having((SendFailure e) => e.statusCode, 'statusCode', 413)),
      );
      expect(received, isEmpty);
    });

    test('旧客户端回 200：先 cancel 僵尸会话，再抛「请升级到新版本」', () async {
      final List<String> canceled = <String>[];
      final HttpServer server =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((HttpRequest request) async {
        await request.drain<void>();
        if (request.uri.path == WispProtocol.cancelPath) {
          canceled.add(request.uri.queryParameters['sessionId'] ?? '');
          request.response.statusCode = 200;
        } else {
          // 模拟旧客户端：把这条消息当成普通 .txt 文件接收，回 200 + sessionId。
          request.response.statusCode = 200;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(<String, dynamic>{
            'sessionId': 'zombie-session',
            'files': <String, dynamic>{},
          }));
        }
        await request.response.close();
      });

      await expectLater(
        _sender().sendTextMessage(_deviceFor(server.port), id: 'm-4', text: 'hi'),
        throwsA(isA<SendFailure>()
            .having((SendFailure e) => e.statusCode, 'statusCode', 200)
            .having((SendFailure e) => e.message, 'message',
                contains('升级到新版本'))),
      );
      expect(canceled, <String>['zombie-session'],
          reason: '旧客户端留下的僵尸会话要被 cancel 清理掉，且不留 fallback');
    });
  });
}
