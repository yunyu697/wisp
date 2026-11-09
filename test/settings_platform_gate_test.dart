import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:wisp/models/device.dart';
import 'package:wisp/services/desktop_service.dart';
import 'package:wisp/services/settings_service.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/settings_page.dart';

/// 依赖原生实现的设置项，只该出现在**真的实现了**的平台。
///
/// 这些开关之前在各平台都显示：macOS 点下去原生层回
/// FlutterMethodNotImplemented，界面照旧切换，用户看到的是"开关点了没反应"。
///
/// 现在 macOS 用 `macos/Runner/WispOverlay.swift` 补齐了桌面浮层，
/// 所以悬浮球这两个开关在 macOS 上必须回来；托盘最小化（macOS 关窗驻留
/// 菜单栏）、静默启动、服务守护（SCM）仍然只有 Windows 有。
void main() {
  final AppState state = AppState()
    ..settings = const WispSettings(
      alias: '测试机',
      fingerprint: '42df24cbe1a07d3f9b6c8e5a2d4f1b73',
      deviceKind: DeviceKind.desktop,
    );

  Widget host(Widget child, {AppState? value}) =>
      ChangeNotifierProvider<AppState>.value(
        value: value ?? state,
        child: MaterialApp(home: Scaffold(body: child)),
      );

  Future<void> pumpSettings(WidgetTester tester) async {
    // 设置页很长，矮视口下"系统"分组不会被构建出来，断言会假阴性。
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(const SettingsPage()));
    await tester.pump();
  }

  const List<String> floatingBallRows = <String>[
    '桌面悬浮球',
    '悬浮球展开延时',
  ];

  const List<String> windowsOnlyRows = <String>[
    '关闭时最小化到托盘',
    '静默启动',
    '服务守护',
  ];

  tearDown(() {
    DesktopService.debugSetDesktopCapabilities(null);
    DesktopService.debugSetDesktopPlatform(null);
  });

  testWidgets('不支持原生桌面能力的平台：这些开关一个都不显示', (WidgetTester tester) async {
    DesktopService.debugSetDesktopCapabilities(false);
    await pumpSettings(tester);

    for (final String title in <String>[...floatingBallRows, ...windowsOnlyRows]) {
      expect(find.text(title), findsNothing, reason: '「$title」在这个平台没有实现，不该显示');
    }
    // 纯 Dart 侧的设置必须还在——别把整组一起藏了。
    expect(find.text('自动接收'), findsOneWidget);
    expect(find.text('保存位置'), findsOneWidget);
  });

  testWidgets('Windows：原生桌面能力的开关照常显示', (WidgetTester tester) async {
    DesktopService.debugSetDesktopCapabilities(true);
    await pumpSettings(tester);

    for (final String title in <String>[...floatingBallRows, ...windowsOnlyRows]) {
      expect(find.text(title), findsOneWidget, reason: '「$title」在 Windows 上是实现了的');
    }
  });

  testWidgets('macOS：有悬浮球，没有托盘/静默启动/服务守护', (WidgetTester tester) async {
    DesktopService.debugSetDesktopPlatform(DesktopPlatform.macos);
    await pumpSettings(tester);

    for (final String title in floatingBallRows) {
      expect(find.text(title), findsOneWidget,
          reason: '「$title」在 macOS 上有 WispOverlay 原生实现，必须显示');
    }
    for (final String title in windowsOnlyRows) {
      expect(find.text(title), findsNothing,
          reason: '「$title」在 macOS 上没有原生实现，不该显示');
    }
  });

  testWidgets('Linux：一个原生开关都不显示', (WidgetTester tester) async {
    DesktopService.debugSetDesktopPlatform(DesktopPlatform.linux);
    await pumpSettings(tester);

    for (final String title in <String>[...floatingBallRows, ...windowsOnlyRows]) {
      expect(find.text(title), findsNothing, reason: '「$title」在 Linux 上没有实现');
    }
  });

  testWidgets('开机启动：三个桌面平台都显示，移动端隐藏', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 每次都新建一个 AppState：开机启动的能力是在构造时按平台判断的，
    // 复用文件级那个实例会拿到第一次构造时的平台。
    for (final DesktopPlatform target in <DesktopPlatform>[
      DesktopPlatform.windows,
      DesktopPlatform.macos,
      DesktopPlatform.linux,
    ]) {
      DesktopService.debugSetDesktopPlatform(target);
      await tester.pumpWidget(
          host(const SettingsPage(), value: AppState()));
      await tester.pump();
      expect(find.text('开机启动'), findsOneWidget,
          reason: '$target 已实现登录自启，开关必须显示');
    }

    DesktopService.debugSetDesktopPlatform(DesktopPlatform.mobile);
    await tester.pumpWidget(host(const SettingsPage(), value: AppState()));
    await tester.pump();
    expect(find.text('开机启动'), findsNothing,
        reason: '移动端没有"登录"这个概念，不该出现点了没反应的开关');
  });
}
