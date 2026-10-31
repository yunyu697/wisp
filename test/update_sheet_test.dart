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
          body: UpdateSheet(checkOverride: checkOverride),
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
      await pump(
        tester,
        () async =>
            const WispUpdateInfo(latestVersion: WispReleaseNotes.currentVersion),
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
  });
}
