import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisp/core/design/app_theme.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/shell/home_shell.dart';
import 'package:wisp/ui/widgets/wisp_bottom_nav.dart';

/// 联系人 → 会话跳转护栏。
///
/// 曾经的 bug：联系人页只发 requestOpenConversation，会话页在后台把会话
/// 选中了，但导航还停在「联系人」页——宽屏下点了完全没反应。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.ensureInitialized();
    final TestFlutterView view = binding.platformDispatcher.implicitView!;
    view.physicalSize = const Size(1170, 2532);
    view.devicePixelRatio = 3.0;
  });

  tearDown(() {
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.implicitView!.reset();
  });

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: WispTheme.light(),
          home: const HomeShell(),
        ),
      );

  testWidgets('点联系人「发消息」会切回会话导航并打开聊天',
      (WidgetTester tester) async {
    final AppState state = AppState();
    final WispDevice device = WispDevice(
      alias: 'Tyler 的 iPhone',
      ip: '192.168.1.31',
      fingerprint: 'a' * 64,
      kind: DeviceKind.mobile,
    );
    state.acceptDeviceForTest(device);
    state.openChat(device);

    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('联系人').last);
    await tester.pumpAndSettle();
    expect(find.text('发消息'), findsOneWidget);
    expect(tester.widget<WispBottomNav>(find.byType(WispBottomNav)).index, 1);

    await tester.tap(find.text('发消息'));
    await tester.pumpAndSettle();

    // 外壳必须把导航切回「会话」（index 0），否则用户眼前没变化。
    // 窄屏会 push ChatPage 路由，底栏此时在 offstage 树里，要显式关掉跳过。
    final WispBottomNav nav = tester.widget<WispBottomNav>(
      find.byType(WispBottomNav, skipOffstage: false),
    );
    expect(nav.index, 0);
  });

  testWidgets('离线联系人也能打开会话：身份在簿里就有历史可看',
      (WidgetTester tester) async {
    final AppState state = AppState();
    final WispDevice device = WispDevice(
      alias: '书房的旧笔记本',
      ip: '192.168.1.77',
      fingerprint: 'c' * 64,
      kind: DeviceKind.desktop,
    );
    state.acceptDeviceForTest(device);
    // 联系人簿留存身份，但设备已下线、且此前从没聊过天。
    state.devices.clear();
    expect(state.conversationOf(device.fingerprint), isNull);

    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('联系人').last);
    await tester.pumpAndSettle();
    expect(find.text('发消息'), findsOneWidget);

    await tester.tap(find.text('发消息'));
    await tester.pumpAndSettle();

    // 以前这条路径会直接 return（连 banner 都没通知出去），点了完全没反应。
    expect(state.conversationOf(device.fingerprint), isNotNull);
    final WispBottomNav nav = tester.widget<WispBottomNav>(
      find.byType(WispBottomNav, skipOffstage: false),
    );
    expect(nav.index, 0);
  });
}
