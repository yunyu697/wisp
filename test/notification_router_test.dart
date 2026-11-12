import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/services/desktop_service.dart';
import 'package:wisp/services/notification_router.dart';

/// 通知分流规则的回归测试。
///
/// 常驻悬浮球已退役：判定只看 userIsLooking（visible && active），
/// ballEnabled 等旧字段一律不再影响落点。
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

  test('主窗口可见且激活 → 应用内弹层（inApp）', () {
    expect(decideIncomingSurface(state(visible: true, active: true)),
        NotificationSurface.inApp);
  });

  test('主窗口可见但不是激活窗口 → 桌面通知卡（toast）', () {
    expect(decideIncomingSurface(state(visible: true, active: false)),
        NotificationSurface.toast);
  });

  test('主窗口没开 → 桌面通知卡（toast）', () {
    expect(decideIncomingSurface(state()), NotificationSurface.toast);
  });

  test('ballEnabled 不再影响判定：四种窗口状态下结果与 ball 无关', () {
    for (final bool ball in <bool>[false, true]) {
      for (final bool visible in <bool>[true, false]) {
        for (final bool active in <bool>[true, false]) {
          final NotificationSurface surface = decideIncomingSurface(
              state(visible: visible, active: active, ball: ball));
          final NotificationSurface expected = visible && active
              ? NotificationSurface.inApp
              : NotificationSurface.toast;
          expect(surface, expected,
              reason: 'ball=$ball visible=$visible active=$active');
          expect(surface, isNot(NotificationSurface.bubble),
              reason: '常驻悬浮球已退役，不该再返回 bubble');
        }
      }
    }
  });

  test('ballEnabled=true 且主窗口被切走 → 桌面通知卡（不再是气泡）', () {
    expect(
        decideIncomingSurface(state(visible: true, active: false, ball: true)),
        NotificationSurface.toast);
  });

  test('ballEnabled=true 且主窗口没开 → 桌面通知卡', () {
    expect(decideIncomingSurface(state(ball: true)), NotificationSurface.toast);
  });

  test('useBallFlow 对所有落点恒为 false（悬浮球已退役）', () {
    for (final NotificationSurface surface in NotificationSurface.values) {
      expect(useBallFlow(surface), isFalse, reason: '$surface');
    }
  });

  test('拿不到原生状态时不能静默吞掉通知：要照常弹桌面提醒', () {
    // 以前这里当成'用户在看着主窗口'，于是状态一旦拿不到就把通知吞了——
    // 用户反馈过'要第二次才会出现'，第一次正好被这个默认值吃掉。
    // 现在拿不到状态就照常打扰：宁可多弹一次，也不能一声不吭。
    expect(DesktopWindowState.unknown.userIsLooking, isFalse);
    expect(decideIncomingSurface(DesktopWindowState.unknown),
        NotificationSurface.toast);
  });
}
