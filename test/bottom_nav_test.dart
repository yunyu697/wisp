import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wisp/core/design/app_theme.dart';
import 'package:wisp/ui/widgets/wisp_bottom_nav.dart';

import 'support/test_fonts.dart';

/// 底栏专项测试。
///
/// 底栏出过一个问题：高亮胶囊的高度和位置是手算的常数，
/// 结果切断了文字。截图只能事后发现，这里同时用几何断言把关系钉死——
/// 胶囊必须完整包住「图标 + 文字」这一组内容。
void main() {
  late String fontFamily;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    fontFamily = await loadTestFonts();
  });

  Widget host(int index, {ThemeMode mode = ThemeMode.light}) {
    final ThemeData base = mode == ThemeMode.dark
        ? WispTheme.dark(fontFamily: fontFamily)
        : WispTheme.light(fontFamily: fontFamily);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: base,
      home: Scaffold(
        body: const SizedBox.shrink(),
        bottomNavigationBar: WispBottomNav(index: index, onChanged: (_) {}),
      ),
    );
  }

  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  /// 找到高亮块：底栏里唯一一个带渐变的容器。
  Finder pill() => find.byWidgetPredicate(
    (Widget w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).gradient != null,
  );

  testWidgets('高亮块完整包住图标与文字', (WidgetTester tester) async {
    usePhone(tester);
    await tester.pumpWidget(host(0));
    await tester.pump(const Duration(milliseconds: 600));

    final Rect pillRect = tester.getRect(pill());
    final Rect iconRect = tester.getRect(find.byIcon(Icons.radar_rounded).first);
    final Rect labelRect = tester.getRect(find.text('附近'));

    expect(pillRect.contains(iconRect.topLeft), isTrue, reason: '高亮块没盖住图标顶部');
    expect(pillRect.contains(iconRect.bottomRight), isTrue, reason: '高亮块没盖住图标底部');
    expect(pillRect.contains(labelRect.topLeft), isTrue, reason: '高亮块没盖住文字顶部');
    expect(pillRect.contains(labelRect.bottomRight), isTrue, reason: '高亮块没盖住文字底部');
  });

  testWidgets('每个标签页的高亮块都完整包住内容', (WidgetTester tester) async {
    usePhone(tester);
    const List<String> labels = <String>['附近', '发送', '记录', '设置'];

    for (int i = 0; i < labels.length; i++) {
      await tester.pumpWidget(host(i));
      await tester.pump(const Duration(milliseconds: 600));

      final Rect pillRect = tester.getRect(pill());
      final Rect labelRect = tester.getRect(find.text(labels[i]));
      expect(
        pillRect.contains(labelRect.topLeft) && pillRect.contains(labelRect.bottomRight),
        isTrue,
        reason: '「${labels[i]}」的高亮块没盖住文字',
      );
    }
  });

  testWidgets('高亮块随选中项滑动', (WidgetTester tester) async {
    usePhone(tester);
    await tester.pumpWidget(host(0));
    await tester.pump(const Duration(milliseconds: 600));
    final double leftBefore = tester.getRect(pill()).left;

    await tester.pumpWidget(host(2));
    await tester.pump(const Duration(milliseconds: 600));
    final double leftAfter = tester.getRect(pill()).left;

    expect(leftAfter, greaterThan(leftBefore), reason: '切到「记录」后高亮块应该往右滑');
  });

  testWidgets('golden: 底栏（浅色）', (WidgetTester tester) async {
    usePhone(tester);
    await tester.pumpWidget(host(0));
    await tester.pump(const Duration(milliseconds: 900));
    await expectLater(find.byType(WispBottomNav), matchesGoldenFile('goldens/06-bottom-nav.png'));
  });

  testWidgets('golden: 底栏（深色）', (WidgetTester tester) async {
    usePhone(tester);
    await tester.pumpWidget(host(0, mode: ThemeMode.dark));
    await tester.pump(const Duration(milliseconds: 900));
    await expectLater(find.byType(WispBottomNav), matchesGoldenFile('goldens/07-bottom-nav-dark.png'));
  });
}
