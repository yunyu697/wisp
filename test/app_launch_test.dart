import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:wisp/app.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/shell/home_shell.dart';

/// 启动白屏护栏。
///
/// 曾经的写法：根部 TickerMode + AnimatedSwitcher。窗口隐藏（静默启动、
/// 托盘态）时 ticker 被静音，启动页 → 主页的淡入切换会卡在全透明的一帧，
/// 用户从托盘打开只看到一片白。现在启动阶段不静音、也不做过渡动画。
void main() {
  setUp(() {
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.ensureInitialized();
    final TestFlutterView view = binding.platformDispatcher.implicitView!;
    view.physicalSize = const Size(1200, 900);
    view.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.implicitView!.reset();
  });

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const WispApp(),
      );

  testWidgets('就绪前后直接切换，没有会卡住的过渡动画', (WidgetTester tester) async {
    final AppState state = AppState()..ready = false;
    await tester.pumpWidget(host(state));

    expect(find.text('只在近处发生的传递'), findsOneWidget);
    expect(find.byType(AnimatedSwitcher), findsNothing);
    expect(find.byType(HomeShell), findsNothing);

    state.ready = true;
    state.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.text('只在近处发生的传递'), findsNothing);
  });

  testWidgets('启动阶段即使窗口不可见也不静音 ticker', (WidgetTester tester) async {
    final AppState state = AppState()
      ..ready = false
      ..mainWindowVisible = false;
    await tester.pumpWidget(host(state));

    // 启动页自己的淡入必须能跑完，否则就是一片白。
    // MaterialApp 内部也有若干 TickerMode，所以断言"没有任何一个被静音"。
    expect(
      find.byWidgetPredicate(
          (Widget widget) => widget is TickerMode && !widget.enabled),
      findsNothing,
    );
  });
}
