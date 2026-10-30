import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisp/core/design/app_theme.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/services/settings_service.dart';
import 'package:wisp/services/update_service.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/settings_page.dart';

import 'support/test_fonts.dart';

/// 「自动检查更新」设置项：频率选择落盘 + 新版本挂起后的入口文案。
/// 通过 mock SharedPreferences 让 updateSettings 的落盘在测试里可用。
void main() {
  late String fontFamily;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    fontFamily = await loadTestFonts();
  });

  AppState newState() {
    SharedPreferences.setMockInitialValues(<String, String>{});
    return AppState()
      ..settings = const WispSettings(
        alias: 'Tyler 的 PC',
        fingerprint: '42df24cbe1a07d3f9b6c8e5a2d4f1b73',
        deviceKind: DeviceKind.desktop,
      );
  }

  Widget host(AppState state) {
    return ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: WispTheme.light(fontFamily: fontFamily),
        home: const Scaffold(body: SettingsPage()),
      ),
    );
  }

  Future<void> openCadenceSheet(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(host(state));
    await tester.scrollUntilVisible(
      find.text('自动检查更新'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动检查更新'));
    await tester.pumpAndSettle();
  }

  group('自动检查更新设置项', () {
    testWidgets('默认每天一次，点开可选每周一次并立即生效', (WidgetTester tester) async {
      final AppState state = newState();
      await openCadenceSheet(tester, state);

      // 弹层四个选项齐全，当前选中的是默认的每天一次。
      expect(find.text('关闭'), findsOneWidget);
      expect(find.text('每次启动'), findsOneWidget);
      expect(find.text('每天一次'), findsWidgets); // 入口行 + 选项
      expect(find.text('每周一次'), findsOneWidget);

      await tester.tap(find.text('每周一次').last);
      await tester.pumpAndSettle();

      expect(state.settings.updateCheckHours, WispUpdateCadence.weekly);
      // 弹层关掉后入口行的值跟着变。
      expect(find.text('每周一次'), findsOneWidget);
    });

    testWidgets('选择关闭后频率归零，只剩手动检查', (WidgetTester tester) async {
      final AppState state = newState();
      await openCadenceSheet(tester, state);

      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();

      expect(state.settings.updateCheckHours, WispUpdateCadence.off);
      // 弹层标题收掉，入口行还在。
      expect(find.text('到点后台静默比对一次'), findsNothing);
      expect(find.text('关闭'), findsOneWidget);
    });

    testWidgets('发现新版本时入口行改报新版本号', (WidgetTester tester) async {
      final AppState state = newState();
      state.pendingUpdate = const WispUpdateInfo(latestVersion: '9.9.9');
      await tester.pumpWidget(host(state));

      await tester.scrollUntilVisible(
        find.text('检查更新'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('新版本 v9.9.9'), findsOneWidget);
      expect(find.text('已发现新版本，点「检查更新」查看详情'), findsOneWidget);
    });

    testWidgets('手动检查后刷新自动检查时间戳', (WidgetTester tester) async {
      final AppState state = newState();
      expect(state.settings.lastUpdateCheckMs, 0);
      await state.markManualUpdateCheck();
      expect(state.settings.lastUpdateCheckMs, greaterThan(0));
    });
  });
}
