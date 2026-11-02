import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisp/models/device.dart';
import 'package:wisp/models/message.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/chat_page.dart';
import 'package:wisp/ui/pages/messages_page.dart';

/// 消息页 / 聊天页的界面测试。
///
/// 这里不发真实请求：`flutter_test` 的 binding 把 HttpClient 换成了"一律 400"
/// 的桩，所以点"发送"之后消息必然落到失败态——对断言"气泡确实出现了"来说
/// 完全够用，真实的收发链路由 `message_test.dart` 覆盖。
const String _peerKey = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

WispDevice _peer({bool capable = true}) => WispDevice(
      alias: 'Tyler 的 iPhone',
      ip: '192.168.1.31',
      fingerprint: _peerKey,
      kind: DeviceKind.mobile,
      messageCapable: capable,
    );

Conversation _conversation({int unread = 0}) => Conversation(
      peerKey: _peerKey,
      peerAlias: 'Tyler 的 iPhone',
      peerIp: '192.168.1.31',
      unread: unread,
      messages: <ChatMessage>[
        ChatMessage(
          id: 'm1',
          direction: MessageDirection.incoming,
          text: '这条是对方发来的',
          time: DateTime.now().subtract(const Duration(minutes: 2)),
        ),
        ChatMessage(
          id: 'm2',
          direction: MessageDirection.outgoing,
          text: '这条是我发出去的',
          time: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
      ],
    );

Future<AppState> _pump(WidgetTester tester, Widget page, {WispDevice? device}) async {
  final AppState state = AppState();
  if (device != null) state.acceptDeviceForTest(device);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(home: page),
    ),
  );
  await tester.pump();
  return state;
}

void main() {
  setUp(() {
    // 消息收发会顺手落盘，没有这行 unawaited 的 save 会变成未处理异常。
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('会话列表显示未读角标，点进去打开聊天页', (WidgetTester tester) async {
    final AppState state = await _pump(
      tester,
      const MessagesPage(),
      device: _peer(),
    );
    state.seedConversationForTest(_conversation(unread: 3));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Tyler 的 iPhone'), findsOneWidget);
    expect(find.text('3'), findsOneWidget, reason: '未读角标没画出来');
    expect(state.unreadMessages, 3);

    await tester.tap(find.text('Tyler 的 iPhone'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('这条是对方发来的'), findsOneWidget);
    expect(find.text('这条是我发出去的'), findsOneWidget);
    expect(state.unreadMessages, 0, reason: '进入会话后必须清掉未读');
  });

  testWidgets('对方不在线时输入框禁用并给出原因', (WidgetTester tester) async {
    // 设备列表里没有这台设备 = 已经离线。
    final AppState state = await _pump(
      tester,
      const ChatPage(peerKey: _peerKey),
    );
    state.seedConversationForTest(_conversation());
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('对方不在附近，消息发不出去'), findsOneWidget);
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
  });

  testWidgets('点剪贴板按钮把内容发成一条消息（不落文件）', (WidgetTester tester) async {
    const String clipboard = 'flutter test --exclude-tags golden';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': clipboard};
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final AppState state = await _pump(
      tester,
      const ChatPage(peerKey: _peerKey),
      device: _peer(),
    );
    state.seedConversationForTest(Conversation(
      peerKey: _peerKey,
      peerAlias: 'Tyler 的 iPhone',
      peerIp: '192.168.1.31',
    ));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byTooltip('发送剪贴板内容'));
    await tester.pumpAndSettle();

    // 气泡出现即说明内容以"消息"的形式进了会话；请求本身在这个环境里必然
    // 失败（HttpClient 被换成了 400 桩），所以还要能看到重试入口。
    expect(find.text(clipboard), findsOneWidget);
    expect(find.text('发送失败，点这里重试'), findsOneWidget);

    final Conversation conversation = state.conversationOf(_peerKey)!;
    expect(conversation.messages, hasLength(1));
    expect(conversation.messages.single.text, clipboard);
    expect(conversation.messages.single.isOutgoing, isTrue);
  });

  testWidgets('对方不支持消息时，聊天页明说只能收发文件', (WidgetTester tester) async {
    final AppState state = await _pump(
      tester,
      const ChatPage(peerKey: _peerKey),
      device: _peer(capable: false),
    );
    state.seedConversationForTest(_conversation());
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('对方不是 Wisp（或版本太旧），只能收发文件'), findsOneWidget);
  });
}
