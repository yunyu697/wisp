import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisp/core/design/app_theme.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/chat_page.dart';
import 'package:wisp/ui/shell/home_shell.dart';
import 'package:wisp/ui/widgets/contact_inspector.dart';
import 'package:wisp/ui/widgets/wisp_bottom_nav.dart';

/// 会话导航的「聊天软件操作逻辑」护栏。
///
/// 曾经的 bug：只有 ≥1100 的窗口才把聊天内嵌在右侧，中等桌面窗口（例如
/// 1000×700）点会话会 push 一个全屏 ChatPage，把侧边导航和会话列表一起
/// 盖掉——用户看到的就是「进入会话之后，左侧栏会消失」。微信桌面的行为
/// 是点会话只换右侧内容，左栏永远在；手机才是列表 → 全屏聊天 → 返回。
/// 这里把四档视口的行为钉死，防止断点再被改回去。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.implicitView!.reset();
  });

  void viewport(WidgetTester tester, Size logical) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = logical;
    addTearDown(tester.view.reset);
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: WispTheme.light(),
          home: const HomeShell(),
        ),
      );

  AppState stateWithChats({bool two = false}) {
    final AppState state = AppState();
    final List<List<String>> devices = <List<String>>[
      <String>['客厅的 Mac mini', '192.168.1.24'],
      if (two) <String>['Tyler 的 iPhone', '192.168.1.31'],
    ];
    for (final List<String> item in devices) {
      final WispDevice device = WispDevice(
        alias: item[0],
        ip: item[1],
        // 指纹就是联系人/会话的键，两台设备必须不同。
        fingerprint: item[0] == '客厅的 Mac mini' ? 'b' * 64 : 'c' * 64,
        kind: DeviceKind.desktop,
      );
      state.acceptDeviceForTest(device);
      state.openChat(device);
    }
    return state;
  }

  ChatPage chatOf(WidgetTester tester) =>
      tester.widget<ChatPage>(find.byType(ChatPage));

  testWidgets('中等桌面窗口 1000x700：点会话后左侧导航与会话列表常驻',
      (WidgetTester tester) async {
    viewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(stateWithChats()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('客厅的 Mac mini').first);
    await tester.pumpAndSettle();

    // 聊天是内嵌的，不是 push 上来的全屏路由：没有返回键，头部是设计稿 01
    // 那三个圆角方按钮，「关闭会话」收进「⋯」菜单。
    expect(chatOf(tester).embedded, isTrue);
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    expect(find.byTooltip('搜索这段对话'), findsOneWidget);
    expect(find.byTooltip('联系人资料'), findsOneWidget);
    expect(find.byTooltip('更多'), findsOneWidget);
    // 侧边导航 + 左栏搜索框都还在，身份卡栏让位给消息区。
    expect(find.byType(WispNavRail), findsOneWidget);
    expect(find.text('搜索联系人、文件或内容'), findsOneWidget);
    expect(find.byType(ContactInspector), findsNothing);
  });

  testWidgets('宽桌面窗口 1440x900：三栏主场，左栏与身份卡栏都在',
      (WidgetTester tester) async {
    viewport(tester, const Size(1440, 900));
    await tester.pumpWidget(host(stateWithChats()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('客厅的 Mac mini').first);
    await tester.pumpAndSettle();

    expect(chatOf(tester).embedded, isTrue);
    expect(find.byType(WispNavRail), findsOneWidget);
    expect(find.text('搜索联系人、文件或内容'), findsOneWidget);
    expect(find.byType(ContactInspector), findsOneWidget);
  });

  testWidgets('分栏里切换会话只换右侧，左栏不重建消失',
      (WidgetTester tester) async {
    viewport(tester, const Size(1000, 700));
    final AppState state = stateWithChats(two: true);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('客厅的 Mac mini').first);
    await tester.pumpAndSettle();
    final String first = chatOf(tester).peerKey;

    await tester.tap(find.text('Tyler 的 iPhone').first);
    await tester.pumpAndSettle();

    expect(chatOf(tester).peerKey, isNot(first));
    expect(find.text('搜索联系人、文件或内容'), findsOneWidget);
    expect(find.byType(WispNavRail), findsOneWidget);
    expect(find.byType(ContactInspector), findsNothing);
  });

  testWidgets('手机竖屏：全屏聊天 + 顶部返回键，返回回到会话列表',
      (WidgetTester tester) async {
    viewport(tester, const Size(390, 844));
    await tester.pumpWidget(host(stateWithChats()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('客厅的 Mac mini').first);
    await tester.pumpAndSettle();

    expect(chatOf(tester).embedded, isFalse);
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsNothing);
    expect(find.byType(WispBottomNav), findsOneWidget);
  });

  testWidgets('手机横屏 844x390：不误判成分栏，仍是单栏 + 返回',
      (WidgetTester tester) async {
    viewport(tester, const Size(844, 390));
    await tester.pumpWidget(host(stateWithChats()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('客厅的 Mac mini').first);
    await tester.pumpAndSettle();

    expect(chatOf(tester).embedded, isFalse);
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(find.text('搜索联系人、文件或内容'), findsNothing);
  });
}
