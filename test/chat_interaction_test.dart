import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisp/core/design/app_theme.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/models/message.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/chat_page.dart';
import 'package:wisp/ui/pages/contacts_page.dart';
import 'package:wisp/ui/shell/home_shell.dart';
import 'package:wisp/ui/widgets/wisp_bottom_nav.dart';

/// 用户三条实机反馈的回归护栏：
/// 1. 桌面点开会话后左侧四项导航不能消失；
/// 2. 联系人空态必须说明发现状态，并有可点的扫描入口；
/// 3. 单条消息必须有可见的操作入口，且删除只删这一条。
void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Widget host(Widget child, AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: WispTheme.light(),
          home: Scaffold(body: child),
        ),
      );

  testWidgets('桌面窄窗口点开会话，左侧导航仍然常驻',
      (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final AppState state = AppState();
    final WispDevice device = WispDevice(
      alias: '客厅的 Mac mini',
      ip: '192.168.1.42',
      fingerprint: 'b' * 32,
      kind: DeviceKind.desktop,
    );
    state.acceptDeviceForTest(device);
    state.seedConversationForTest(Conversation(
      peerKey: device.key,
      peerAlias: device.alias,
      peerIp: device.ip,
      messages: <ChatMessage>[
        ChatMessage(
          id: 'd1',
          direction: MessageDirection.incoming,
          text: '收到，我这边已经跑起来了',
          time: DateTime.now(),
        ),
      ],
    ));

    await tester.pumpWidget(host(const HomeShell(), state));
    await tester.pumpAndSettle();
    expect(find.byType(WispNavRail), findsOneWidget);
    expect(find.byType(WispBottomNav), findsNothing);

    await tester.tap(find.text('客厅的 Mac mini').first);
    await tester.pumpAndSettle();

    expect(find.byType(WispNavRail), findsOneWidget);
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.byType(WispBottomNav), findsNothing);
    // 必须在测试体里还原：放到 addTearDown 会在 foundation 不变量检查之后。
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('联系人空态说明发现状态并提供扫描入口', (WidgetTester tester) async {
    final AppState state = AppState();
    await tester.pumpWidget(host(const ContactsPage(), state));
    await tester.pumpAndSettle();

    expect(find.text('附近没有设备'), findsOneWidget);
    expect(find.text('立即扫描网段'), findsOneWidget);
    // 没收到任何广播时，明确告诉用户去查 UDP 53317，而不是让他瞎猜。
    expect(find.textContaining('UDP 53317'), findsWidgets);
  });

  testWidgets('单条消息可复制可删除，删除不动整段会话',
      (WidgetTester tester) async {
    final AppState state = AppState();
    final WispDevice device = WispDevice(
      alias: 'Tyler 的 iPhone',
      ip: '192.168.1.31',
      fingerprint: 'a' * 32,
      kind: DeviceKind.mobile,
    );
    final Conversation conversation = Conversation(
      peerKey: device.key,
      peerAlias: device.alias,
      peerIp: device.ip,
      messages: <ChatMessage>[
        ChatMessage(
          id: 'keep',
          direction: MessageDirection.outgoing,
          text: '这条要留下',
          time: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
        ChatMessage(
          id: 'drop',
          direction: MessageDirection.incoming,
          text: '这条要删掉',
          time: DateTime.now(),
        ),
      ],
    );
    state.seedConversationForTest(conversation);

    await tester.pumpWidget(
      host(
        ChatPage(peerKey: device.key, embedded: true),
        state,
      ),
    );
    await tester.pumpAndSettle();

    // 操作入口必须可见，不能只靠没提示的长按。
    expect(find.byTooltip('消息操作'), findsNWidgets(2));
    // 消息流是 reverse:true，屏幕上第一条才是最新的「drop」。
    await tester.tap(find.byTooltip('消息操作').first);
    await tester.pumpAndSettle();
    expect(find.text('复制文字'), findsOneWidget);
    expect(find.text('删除这条消息'), findsOneWidget);

    await tester.tap(find.text('删除这条消息'));
    await tester.pumpAndSettle();

    expect(
      state.conversationOf(device.key)!.messages.map((ChatMessage m) => m.id),
      <String>['keep'],
    );
    expect(state.conversationOf(device.key), isNotNull);
  });
}
