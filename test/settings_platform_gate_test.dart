import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:wisp/models/device.dart';
import 'package:wisp/services/desktop_service.dart';
import 'package:wisp/services/settings_service.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/settings_page.dart';

/// 依赖原生实现的设置项，只该出现在**真的实现了**的平台（当前只有 Windows）。
///
/// 这些开关之前在各平台都显示：macOS 点下去原生层回
/// FlutterMethodNotImplemented，界面照旧切换，用户看到的是"开关点了没反应"。
void main() {
  final AppState state = AppState()
    ..settings = const WispSettings(
      alias: '测试机',
      fingerprint: '42df24cbe1a07d3f9b6c8e5a2d4f1b73',
      deviceKind: DeviceKind.desktop,
    );

  Widget host(Widget child) => ChangeNotifierProvider<AppState>.value(
        value: state,
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

  tearDown(() => DesktopService.debugSetDesktopCapabilities(null));

  /// 只有 Windows runner 实现了原生支持的几项。
  const List<String> nativeOnly = <String>[
    '桌面悬浮球',
    '悬浮球展开延时',
    '关闭时最小化到托盘',
    '静默启动',
    '服务守护',
  ];

  testWidgets('不支持原生桌面能力的平台：这些开关一个都不显示', (WidgetTester tester) async {
    DesktopService.debugSetDesktopCapabilities(false);
    await pumpSettings(tester);

    for (final String title in nativeOnly) {
      expect(find.text(title), findsNothing, reason: '「$title」在这个平台没有实现，不该显示');
    }
    // 纯 Dart 侧的设置必须还在——别把整组一起藏了。
    expect(find.text('自动接收'), findsOneWidget);
    expect(find.text('保存位置'), findsOneWidget);
  });

  testWidgets('Windows：原生桌面能力的开关照常显示', (WidgetTester tester) async {
    DesktopService.debugSetDesktopCapabilities(true);
    await pumpSettings(tester);

    for (final String title in nativeOnly) {
      expect(find.text(title), findsOneWidget, reason: '「$title」在 Windows 上是实现了的');
    }
  });
}
