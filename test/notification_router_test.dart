import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/services/desktop_service.dart';
import 'package:wisp/services/notification_router.dart';

/// 七条通知分流规则的回归测试。
///
/// 这些规则是产品行为契约，改之前先看这里的用例名。
void main() {
  DesktopWindowState state({
    bool visible = false,
    bool active = false,
    bool ball = false,
  }) =>
      DesktopWindowState(
        visible: visible,
        active: active,
        ballEnabled: ball,
        ballExpanded: ball,
        ballSnapped: false,
      );

  test('规则 1：球未启用 + 主窗口激活 → 主窗口通知', () {
    expect(decideIncomingSurface(state(visible: true, active: true)),
        NotificationSurface.inApp);
  });

  test('规则 1：球未启用 + 主窗口可见但不是激活窗口 → 桌面通知', () {
    expect(decideIncomingSurface(state(visible: true, active: false)),
        NotificationSurface.toast);
  });

  test('规则 2：球未启用 + 主窗口没开 → 桌面通知', () {
    expect(decideIncomingSurface(state()), NotificationSurface.toast);
  });

  test('规则 3：球启用时绝不走桌面通知', () {
    for (final bool visible in <bool>[true, false]) {
      for (final bool active in <bool>[true, false]) {
        final NotificationSurface surface =
            decideIncomingSurface(state(visible: visible, active: active, ball: true));
        expect(surface, isNot(NotificationSurface.toast),
            reason: 'visible=$visible active=$active');
      }
    }
  });

  test('规则 4：球启用 + 主窗口激活 → 主窗口通知', () {
    expect(
        decideIncomingSurface(state(visible: true, active: true, ball: true)),
        NotificationSurface.inApp);
  });

  test('规则 4：球启用 + 主窗口被切走 → 悬浮球通知', () {
    expect(
        decideIncomingSurface(state(visible: true, active: false, ball: true)),
        NotificationSurface.bubble);
  });

  test('规则 5：球启用 + 主窗口没开 → 悬浮球通知', () {
    expect(decideIncomingSurface(state(ball: true)), NotificationSurface.bubble);
  });

  test('流程通道一旦选定就不切换：只有气泡算"悬浮球流程"', () {
    expect(useBallFlow(NotificationSurface.bubble), isTrue);
    expect(useBallFlow(NotificationSurface.toast), isFalse);
    expect(useBallFlow(NotificationSurface.inApp), isFalse);
  });

  test('拿不到原生状态时不能静默吞掉通知：要照常弹桌面提醒', () {
    // 以前这里当成"用户在看着主窗口"，于是状态一旦拿不到就把通知吞了——
    // 用户反馈过"要第二次才会出现"，第一次正好被这个默认值吃掉。
    // 现在拿不到状态就照常打扰：宁可多弹一次，也不能一声不吭。
    expect(DesktopWindowState.unknown.userIsLooking, isFalse);
    expect(decideIncomingSurface(DesktopWindowState.unknown),
        NotificationSurface.toast);
  });
}
