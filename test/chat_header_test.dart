import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisp/models/device.dart';
import 'package:wisp/models/message.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/chat_page.dart';

/// 聊天头对齐设计稿 01 的护栏：三个圆角方按钮「搜索 / 联系人 / ⋯」。
///
/// 这里只钉「按钮真的存在且点了真有反应」，不钉像素；外观由
/// `17-three-column.png` 基准图把关。
const String _peerKey = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const String _hint = '搜索这段对话';

WispDevice _peer() => WispDevice(
      alias: '客厅的 Mac mini',
      ip: '192.168.1.24',
      fingerprint: _peerKey,
      kind: DeviceKind.desktop,
    );

Conversation _conversation() => Conversation(
      peerKey: _peerKey,
      peerAlias: '客厅的 Mac mini',
      peerIp: '192.168.1.24',
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

/// 搜索框和输入框都是 TextField，只能用 hintText 区分。
final Finder _searchField = find.byWidgetPredicate(
  (Widget widget) => widget is TextField && widget.decoration?.hintText == _hint,
);

Future<AppState> _pump(WidgetTester tester, {bool online = true}) async {
  final AppState state = AppState();
  if (online) state.acceptDeviceForTest(_peer());
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: ChatPage(peerKey: _peerKey)),
    ),
  );
  state.seedConversationForTest(_conversation());
  await tester.pump(const Duration(milliseconds: 300));
  return state;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('头部三个按钮都在，删除不再占独立图标', (WidgetTester tester) async {
    await _pump(tester);

    expect(find.byTooltip('搜索这段对话'), findsOneWidget);
    expect(find.byTooltip('联系人资料'), findsOneWidget);
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(
      find.byIcon(Icons.delete_outline_rounded),
      findsNothing,
      reason: '删除应改进「⋯」菜单，头部只留设计稿的三个按钮',
    );
  });

  testWidgets('点搜索换成搜索框，按关键词过滤消息', (WidgetTester tester) async {
    await _pump(tester);
    expect(find.text('这条是我发出去的'), findsOneWidget);

    await tester.tap(find.byTooltip('搜索这段对话'));
    await tester.pumpAndSettle();
    expect(_searchField, findsOneWidget);

    await tester.enterText(_searchField, '对方');
    await tester.pumpAndSettle();

    expect(find.text('这条是对方发来的'), findsOneWidget);
    expect(find.text('这条是我发出去的'), findsNothing);
    expect(find.text('1 / 2'), findsOneWidget);

    // 取消后恢复完整列表，别把过滤状态留在页面上。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('这条是我发出去的'), findsOneWidget);
  });

  testWidgets('搜索没有命中时给出明确空态', (WidgetTester tester) async {
    await _pump(tester);
    await tester.tap(find.byTooltip('搜索这段对话'));
    await tester.pumpAndSettle();

    await tester.enterText(_searchField, '不存在的内容');
    await tester.pumpAndSettle();

    expect(find.textContaining('没有找到「不存在的内容」'), findsOneWidget);
  });

  testWidgets('联系人资料弹层：在线有发文件，离线没有', (WidgetTester tester) async {
    final AppState state = await _pump(tester);

    await tester.tap(find.byTooltip('联系人资料'));
    await tester.pumpAndSettle();
    expect(find.text('稳定标识'), findsOneWidget);
    expect(find.text('免确认接收'), findsOneWidget);
    expect(find.text('给 客厅的 Mac mini 发文件'), findsOneWidget, reason: '在线设备应能直接发文件');
    expect(find.text('删除这段对话'), findsOneWidget);

    await tester.ensureVisible(find.text('删除这段对话'));
    await tester.tap(find.text('删除这段对话'));
    await tester.pumpAndSettle();
    // 危险动作先确认，不直接删。
    expect(find.text('会删掉和 客厅的 Mac mini 的全部聊天记录，不影响任何文件。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.conversationOf(_peerKey), isNotNull);

    // 离线设备：只读历史，不给发送入口。
    final AppState offline = await _pump(tester, online: false);
    await tester.tap(find.byTooltip('联系人资料'));
    await tester.pumpAndSettle();
    expect(find.text('给 客厅的 Mac mini 发文件'), findsNothing);
    expect(offline.conversationOf(_peerKey), isNotNull);
  });

  testWidgets('「⋯」菜单收着设备详情与删除，离线时不出现设备详情', (WidgetTester tester) async {
    await _pump(tester);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('设备详情'), findsOneWidget);
    expect(find.text('删除这段对话'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await _pump(tester, online: false);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('设备详情'), findsNothing);
    expect(find.text('删除这段对话'), findsOneWidget);
  });
}
