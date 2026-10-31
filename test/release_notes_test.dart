import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:wisp/core/design/app_theme.dart';
import 'package:wisp/core/release_notes.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/services/settings_service.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/settings_page.dart';

import 'support/test_fonts.dart';

/// 更新日志：数据完整性 + 设置页入口 + 弹层渲染（golden）。
void main() {
  late String fontFamily;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    fontFamily = await loadTestFonts();
  });

  group('更新日志数据', () {
    test('当前版本在列表里且只有它标记为当前', () {
      expect(
        WispReleaseNotes.entries.any((WispReleaseEntry e) => e.isCurrent),
        isTrue,
        reason: 'currentVersion 必须能对应到 entries 里的一条，否则弹层没有高亮',
      );
      expect(
        WispReleaseNotes.entries.where((WispReleaseEntry e) => e.isCurrent).length,
        1,
      );
    });

    test('每个版本至少有一条改动，且没有空文案', () {
      for (final WispReleaseEntry entry in WispReleaseNotes.entries) {
        expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(entry.version), isTrue,
            reason: '版本号格式异常：${entry.version}');
        expect(entry.changes, isNotEmpty, reason: 'v${entry.version} 没有条目');
        for (final String change in entry.changes) {
          expect(change.trim(), isNotEmpty);
        }
      }
    });

    test('版本号严格递减（新版本在前）', () {
      final List<int> codes = WispReleaseNotes.entries.map((WispReleaseEntry e) {
        final List<String> parts = e.version.split('.');
        return int.parse(parts[0]) * 10000 + int.parse(parts[1]) * 100 + int.parse(parts[2]);
      }).toList();
      for (int i = 1; i < codes.length; i++) {
        expect(codes[i], lessThan(codes[i - 1]), reason: '列表顺序必须是新版本在前');
      }
    });
  });

  group('设置页入口与弹层', () {
    final AppState state = AppState()
      ..settings = const WispSettings(
        alias: 'Tyler 的 MacBook',
        fingerprint: '42df24cbe1a07d3f9b6c8e5a2d4f1b73',
        deviceKind: DeviceKind.desktop,
      );

    Widget host() {
      return ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: WispTheme.light(fontFamily: fontFamily),
          home: const Scaffold(body: SettingsPage()),
        ),
      );
    }

    testWidgets('点「更新日志」弹出全部版本，当前版本有高亮', (WidgetTester tester) async {
      await tester.pumpWidget(host());

      // 「关于」分组在页面底部，先滚到可见再点。
      await tester.scrollUntilVisible(
        find.text('更新日志'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('更新日志'));
      await tester.pumpAndSettle();

      expect(find.text('更新日志'), findsNWidgets(2)); // 入口行 + 弹层标题
      expect(find.textContaining('当前 v${WispReleaseNotes.currentVersion}'), findsOneWidget);
      // ListView 懒构建，断言首项（最新版本）一定已构建。
      // 设置页版本行也可能显示同一个号，所以只要求「至少出现一次」。
      expect(
        find.text('v${WispReleaseNotes.entries.first.version}'),
        findsWidgets,
      );
      expect(find.text('当前版本'), findsOneWidget);
      // ListView 是懒构建的：滚到底才建出最早版本，顺便验证弹层可滚。
      await tester.dragUntilVisible(
        find.text('v1.0.0'),
        find.byType(ListView).last,
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(find.text('v1.0.0'), findsOneWidget);

      // 下滑关掉弹层不影响入口行。
      await tester.drag(find.text('v1.0.0'), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(find.text('当前版本'), findsNothing);
    });

    testWidgets('golden: 更新日志弹层', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(840, 1120);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host());
      await tester.scrollUntilVisible(
        find.text('更新日志'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('更新日志'));
      await tester.pumpAndSettle();

      // 弹层是路由 overlay，不在 SettingsPage 的渲染边界里，
      // 必须截整棵 MaterialApp 才能拍到弹层。
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/15-release-notes.png'),
      );
    });
  });
}
