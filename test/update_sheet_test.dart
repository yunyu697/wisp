import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wisp/core/design/app_theme.dart';
import 'package:wisp/core/release_notes.dart';
import 'package:wisp/services/update_service.dart';
import 'package:wisp/ui/widgets/update_sheet.dart';

import 'support/test_fonts.dart';

/// 「检查更新」弹层：三态（新版本 / 已最新 / 失败）与 golden。
/// 通过 checkOverride 注入桩结果，不碰真实网络。
void main() {
  group('检查更新弹层', () {
    late String fontFamily;

    setUpAll(() async {
      fontFamily = await loadTestFonts();
    });

    // 直接泵弹层本体：设置页里的入口是 const UpdateSheet()，测试从
    // checkOverride 注入桩结果，不碰真实网络。
    Widget host(Future<WispUpdateInfo?> Function() checkOverride) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: WispTheme.light(fontFamily: fontFamily),
        home: Scaffold(
          // 固定「当前版本」，否则每发一版 golden 都要重画（只差几十像素）。
          body: UpdateSheet(
            checkOverride: checkOverride,
            currentVersion: '1.0.0',
          ),
        ),
      );
    }

    Future<void> pump(WidgetTester tester, Future<WispUpdateInfo?> Function() stub) async {
      tester.view.physicalSize = const Size(840, 1120);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(stub));
      await tester.pumpAndSettle();
    }

    /// 比当前版本高一位的版本号。**不能写死**：升版之后写死的值
    /// 就不比当前版新了，测试会悄悄翻车（这次就踩了）。
    /// 局部函数而不是 getter——Dart 不允许在函数体里声明 getter。
    String nextVersion() {
      final List<String> parts = WispReleaseNotes.currentVersion.split('.');
      parts[2] = (int.parse(parts[2]) + 1).toString();
      return parts.join('.');
    }

    Future<WispUpdateInfo> newerStub() async => WispUpdateInfo(
          latestVersion: nextVersion(),
          notes: '拖拽更顺滑，修复若干问题',
          downloadUrl: 'https://example.com/wisp-${nextVersion()}.zip',
        );

    testWidgets('发现新版本：徽章 + 说明 + 官方与镜像入口', (WidgetTester tester) async {
      await pump(tester, newerStub);

      expect(find.text('检查更新'), findsOneWidget);
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('v${nextVersion()}'), findsOneWidget);
      expect(find.text('拖拽更顺滑，修复若干问题'), findsOneWidget);
      expect(find.text('官方源 · GitHub'), findsOneWidget);
      expect(
        find.textContaining('加速镜像 · '),
        findsNWidgets(WispUpdateSource.mirrors.length),
      );
      expect(find.textContaining('已是最新'), findsNothing);
    });

    testWidgets('golden: 发现新版本', tags: 'golden', (WidgetTester tester) async {
      // 固定版本号：跟着 currentVersion 走的话，每发一版这张基准图都要重画。
      await pump(
        tester,
        () async => const WispUpdateInfo(
          latestVersion: '9.9.9',
          notes: '拖拽更顺滑，修复若干问题',
          downloadUrl: 'https://example.com/wisp-9.9.9.zip',
        ),
      );
      await expectLater(
        find.byType(UpdateSheet),
        matchesGoldenFile('goldens/16-update-sheet.png'),
      );
    });

    testWidgets('已是最新：不出现新版本元素，下载入口仍显示', (WidgetTester tester) async {
      // 与 host() 注入的 currentVersion 对齐：两者都写死，才不会随发版漂移。
      await pump(
        tester,
        () async => const WispUpdateInfo(latestVersion: '1.0.0'),
      );

      expect(find.textContaining('已是最新'), findsOneWidget);
      expect(find.text('发现新版本'), findsNothing);
      expect(find.text('官方源 · GitHub'), findsOneWidget);
    });

    testWidgets('检查失败：提示 + 重试，下载入口兜底显示', (WidgetTester tester) async {
      await pump(
        tester,
        () async => throw const SocketException('offline'),
      );

      expect(find.textContaining('连不上更新源'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('官方源 · GitHub'), findsOneWidget);
    });

    testWidgets('下载源下拉：列出官方与全部镜像，能选中镜像', (WidgetTester tester) async {
      await pump(tester, newerStub);

      // 默认选中官方源。
      expect(find.text('下载源'), findsOneWidget);
      expect(find.text('官方源（推荐）'), findsOneWidget);

      await tester.tap(find.byType(DropdownButton<WispUpdateSourceOption>));
      await tester.pumpAndSettle();

      // 展开后每个镜像都有一项可选。
      for (final String prefix in WispUpdateSource.mirrors) {
        expect(find.text(WispUpdateSource.mirrorLabel(prefix)), findsWidgets);
      }

      final String first = WispUpdateSource.mirrorLabel(WispUpdateSource.mirrors.first);
      await tester.tap(find.text(first).last);
      await tester.pumpAndSettle();

      // 选完收起，显示的是选中的镜像。
      expect(find.text(first), findsOneWidget);
      expect(find.text('官方源（推荐）'), findsNothing);
    });
  });

  group('下载结果块', () {
    Widget host(Widget child) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: WispTheme.light(fontFamily: 'Roboto'),
          home: Scaffold(body: child),
        );

    testWidgets('安装包已下好时给出「安装」按钮，点了要真的触发安装', (WidgetTester tester) async {
      int installs = 0;
      await tester.pumpWidget(host(WispUpdateResultCard(
        failed: false,
        message: '安装包已下载到 /home/me/Downloads/wisp-9.9.9-setup.exe',
        onInstall: () => installs++,
        onDismiss: () {},
      )));

      expect(find.text('安装'), findsOneWidget);
      await tester.tap(find.text('安装'));
      expect(installs, 1);
    });

    testWidgets('没有可装的包时不给「安装」按钮（避免点了没反应）', (WidgetTester tester) async {
      await tester.pumpWidget(host(WispUpdateResultCard(
        failed: false,
        message: '已更新到「应用程序」，正在重启 Wisp…',
        onDismiss: () {},
      )));

      expect(find.text('安装'), findsNothing);
      expect(find.text('关闭提示'), findsOneWidget);
    });

    testWidgets('失败态：结论用错误样式，按钮是「重试」', (WidgetTester tester) async {
      await tester.pumpWidget(host(WispUpdateResultCard(
        failed: true,
        message: '下载失败：连不上',
        onDismiss: () {},
      )));

      expect(find.text('重试'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });
  });
}
