import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisp/models/message.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/chat_page.dart';
import 'package:wisp/ui/widgets/attachment_bundle.dart';

/// 多文件折叠的交互契约（用户明确点过名的三条）：
///   1. 一次性发多个文件默认折叠，展开后要**手动**才收起；
///   2. 没退出会话时，新消息 / rebuild 都不能把展开态弄丢；
///   3. 退出会话再进、或切到另一台设备，默认回到折叠。
/// 折叠状态刻意放在 `_ChatPageState` 而不是 `AttachmentBundle` 内部，
/// 所以这里必须在整个 ChatPage 上点按钮，不能只测组件。
const String _peerA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _peerB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

List<ChatAttachment> _files() => <ChatAttachment>[
      const ChatAttachment(
          name: '海边.jpg', size: 1024, path: '', mime: 'image/jpeg'),
      const ChatAttachment(
          name: '报价.pdf', size: 2048, path: '', mime: 'application/pdf'),
      const ChatAttachment(
          name: '录音.m4a', size: 4096, path: '', mime: 'audio/mp4'),
    ];

Conversation _conversation(String peerKey, {int count = 3}) => Conversation(
      peerKey: peerKey,
      peerAlias: '客厅的 Mac mini',
      peerIp: '192.168.1.42',
      messages: <ChatMessage>[
        ChatMessage(
          id: 'files-1',
          direction: MessageDirection.incoming,
          text: '',
          time: DateTime(2026, 1, 1, 10, 30),
          attachments: _files().take(count).toList(),
        ),
      ],
    );

Widget _host(AppState state, {String peerKey = _peerA, Key? chatKey}) {
  return ChangeNotifierProvider<AppState>.value(
    value: state,
    child: MaterialApp(
      home: ChatPage(key: chatKey, peerKey: peerKey),
    ),
  );
}

void main() {
  setUp(() {
    // 会话读写会顺手落盘，widget 测试没有真实插件。
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('单文件不折叠，直接显示文件名与占位预览',
      (WidgetTester tester) async {
    final AppState state = AppState();
    state.seedConversationForTest(_conversation(_peerA, count: 1));
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();

    expect(find.byType(AttachmentBundle), findsOneWidget);
    // 单文件视图里名字出现两次：大占位卡一行 + 底部文件名一行。
    expect(find.text('海边.jpg'), findsNWidgets(2));
    expect(find.text('共 1 个文件'), findsNothing);
    expect(find.text('展开 1 项'), findsNothing);
  });

  testWidgets('3 个文件默认折叠；展开后必须手动收起', (WidgetTester tester) async {
    final AppState state = AppState();
    state.seedConversationForTest(_conversation(_peerA));
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();

    expect(find.text('共 3 个文件'), findsOneWidget);
    expect(find.text('展开 3 项'), findsOneWidget);
    expect(find.text('报价.pdf'), findsNothing,
        reason: '默认折叠时不该把明细画出来');

    await tester.tap(find.text('展开 3 项'));
    await tester.pumpAndSettle();
    expect(find.text('海边.jpg'), findsOneWidget);
    expect(find.text('报价.pdf'), findsOneWidget);
    expect(find.text('录音.m4a'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
    expect(find.text('共 3 个文件'), findsNothing);

    // 同一帧里来一条新消息 / 触发 rebuild，展开态不能被清掉。
    state.seedConversationForTest(_conversation(_peerA));
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    expect(find.text('报价.pdf'), findsOneWidget,
        reason: 'rebuild 把用户手动展开的卡收回去了');
    expect(find.text('共 3 个文件'), findsNothing);

    // 只有再点一次「收起」才折回去。
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.text('共 3 个文件'), findsOneWidget);
    expect(find.text('报价.pdf'), findsNothing);
  });

  testWidgets('切换到另一台设备：展开态清空，回到默认折叠',
      (WidgetTester tester) async {
    final AppState state = AppState();
    state.seedConversationForTest(_conversation(_peerA));
    state.seedConversationForTest(_conversation(_peerB));
    await tester.pumpWidget(_host(state, peerKey: _peerA));
    await tester.pumpAndSettle();

    await tester.tap(find.text('展开 3 项'));
    await tester.pumpAndSettle();
    expect(find.text('报价.pdf'), findsOneWidget);

    // 三栏里换选中会话：peerKey 变化走 didUpdateWidget。
    await tester.pumpWidget(_host(state, peerKey: _peerB));
    await tester.pumpAndSettle();
    expect(find.text('共 3 个文件'), findsOneWidget);
    expect(find.text('报价.pdf'), findsNothing,
        reason: 'A 会话的展开态串到 B 会话里了');
  });

  testWidgets('退出会话重进（ValueKey 重建）：默认折叠',
      (WidgetTester tester) async {
    final AppState state = AppState();
    state.seedConversationForTest(_conversation(_peerA));
    await tester.pumpWidget(
        _host(state, chatKey: const ValueKey<String>('open-1')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('展开 3 项'));
    await tester.pumpAndSettle();
    expect(find.text('报价.pdf'), findsOneWidget);

    // 三栏宿主用 ValueKey(peerKey) 重建内嵌 ChatPage = 退出再进。
    await tester.pumpWidget(
        _host(state, chatKey: const ValueKey<String>('open-2')));
    await tester.pumpAndSettle();
    expect(find.text('共 3 个文件'), findsOneWidget);
    expect(find.text('报价.pdf'), findsNothing);
  });
}
