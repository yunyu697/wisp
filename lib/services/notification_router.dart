import 'desktop_service.dart';

/// 三种通知落点（其中 bubble 随常驻悬浮球一起退役，仅保留枚举值兼容 switch）。
enum NotificationSurface {
  /// 主窗口里的接收弹层（用户正看着窗口，不需要打扰桌面）。
  inApp,

  /// 右下角桌面通知卡。
  toast,

  /// 悬浮球旁边的气泡 —— **已退役**：保留枚举值只为避免别处 switch 编译失败，
  /// 判定逻辑不会再返回它。
  bubble,
}

/// 收到传输请求时该在哪儿提醒 —— 唯一实现。
///
/// 常驻悬浮球与贴球气泡已整体退役，判定不再看 state.ballEnabled：
/// * 只有「主窗口开着且正被使用」（userIsLooking）才走应用内弹层；
/// * 其余一律走桌面通知卡（toast）。
///
/// 「窗口打开后关闭桌面通知、改用主窗口通知」不在这里决定 —— 那是窗口获得
/// 焦点时原生层抛 onWindowRestored 触发的。
NotificationSurface decideIncomingSurface(DesktopWindowState state) {
  if (state.userIsLooking) return NotificationSurface.inApp;
  return NotificationSurface.toast;
}

/// 是否需要用悬浮球承载整条流程 —— **常驻悬浮球已退役**。
///
/// 保留函数签名只为兼容 app_state.dart 等并行改造中的引用，恒返回 false；
/// 所有通知流程一律走桌面通知卡，不再分球/卡片两条通道。
@Deprecated('常驻悬浮球已退役，恒为 false；保留仅为签名兼容')
bool useBallFlow(NotificationSurface surface) => false;
