import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:wisp/models/device.dart';
import 'package:wisp/services/desktop_service.dart';
import 'package:wisp/services/settings_service.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/settings_page.dart';

/// 悬浮球开关只该出现在**真的实现了**悬浮球的平台（当前只有 Windows）。
///
/// 之前 macOS / Android 上也显示这个开关，点下去原生层回
/// FlutterMethodNotImplemented，界面照旧切换——用户看到的是"开关点了没反应"。
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

  tearDown(() => DesktopService.debugSetSupportsFloatingBall(null));

  testWidgets('不支持悬浮球的平台：两条悬浮球设置都不显示', (WidgetTester tester) async {
    DesktopService.debugSetSupportsFloatingBall(false);
    await pumpSettings(tester);

    expect(find.text('桌面悬浮球'), findsNothing);
    expect(find.text('悬浮球展开延时'), findsNothing);
    // 同组的其它设置必须还在——别把整组一起藏了。
    expect(find.text('关闭时最小化到托盘'), findsOneWidget);
    expect(find.text('静默启动'), findsOneWidget);
  });

  testWidgets('支持悬浮球的平台：两条设置照常显示', (WidgetTester tester) async {
    DesktopService.debugSetSupportsFloatingBall(true);
    await pumpSettings(tester);

    expect(find.text('桌面悬浮球'), findsOneWidget);
    expect(find.text('悬浮球展开延时'), findsOneWidget);
  });
}
