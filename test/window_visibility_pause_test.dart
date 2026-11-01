import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/widgets/radar_view.dart';

/// 窗口藏起来之后不许再出帧。
///
/// 背景：主界面那圈"正在寻找附近的设备"雷达是无限循环动画，窗口收进托盘
/// 或者最小化之后，Flutter 引擎照样按 60fps 渲染，空转吃掉 25~50% CPU。
/// 修法是根部一个 TickerMode，按原生推来的可见性统一静音所有 ticker。
void main() {
  group('循环动画跟随窗口可见性', () {
    testWidgets('可见时雷达持续请求新帧', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: TickerMode(enabled: true, child: RadarView()),
      ));
      await tester.pump(const Duration(milliseconds: 16));

      expect(tester.binding.hasScheduledFrame, isTrue,
          reason: '窗口可见时雷达本来就该一直转');
    });

    testWidgets('不可见时雷达不再请求新帧', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: TickerMode(enabled: false, child: RadarView()),
      ));
      await tester.pump(const Duration(milliseconds: 16));

      expect(tester.binding.hasScheduledFrame, isFalse,
          reason: '没人看还按 60fps 画，就是那个 25~50% 的空转');
    });
  });

  group('可见性事件', () {
    test('默认当作可见，否则一启动界面就是静止的', () {
      expect(AppState().mainWindowVisible, isTrue);
    });

    test('隐藏后变 false，重复事件不重复通知', () async {
      final AppState state = AppState();
      int notified = 0;
      state.addListener(() => notified++);

      await state.handleDesktopEventForTest(
        'onWindowVisibility',
        <Object?, Object?>{'visible': false},
      );
      expect(state.mainWindowVisible, isFalse);
      expect(notified, 1);

      // WM_SIZE / WM_SHOWWINDOW 会连着发同样的事件，重复通知等于每拖一下
      // 窗口就把整棵树重建一次。
      await state.handleDesktopEventForTest(
        'onWindowVisibility',
        <Object?, Object?>{'visible': false},
      );
      expect(notified, 1);

      await state.handleDesktopEventForTest(
        'onWindowVisibility',
        <Object?, Object?>{'visible': true},
      );
      expect(state.mainWindowVisible, isTrue);
      expect(notified, 2);
    });

    test('缺字段时按可见处理，宁可多画也不能冻住', () async {
      final AppState state = AppState();
      await state.handleDesktopEventForTest(
        'onWindowVisibility',
        <Object?, Object?>{},
      );
      expect(state.mainWindowVisible, isTrue);
    });
  });
}
