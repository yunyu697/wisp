import 'desktop_service.dart';

/// 三种通知落点。
enum NotificationSurface {
  /// 主窗口里的接收弹层（用户正看着窗口，不需要打扰桌面）。
  inApp,

  /// 右下角桌面通知卡。
  toast,

  /// 悬浮球旁边的气泡。
  bubble,
}

/// 收到传输请求时该在哪儿提醒 —— 七条规则的唯一实现。
///
/// 1. 球未启用 + 主窗口是当前激活窗口 → 主窗口通知；否则桌面通知；
/// 2. 球未启用 + 主窗口没开 → 桌面通知；
/// 3. 球启用 → 一律不用桌面通知；
/// 4. 球启用 + 主窗口是激活窗口 → 主窗口通知；否则悬浮球通知；
/// 5. 球启用 + 主窗口没开 → 悬浮球通知。
///
/// 归纳成两句：
/// * 只有「主窗口开着且正被使用」才走应用内；
/// * 其余情况：球启用走气泡，球没启用走桌面卡片。
///
/// 「窗口打开后关闭桌面通知、改用主窗口通知」不在这里决定 —— 那是窗口获得
/// 焦点时原生层抛 onWindowRestored 触发的（规则 2/5 的后半句）。
NotificationSurface decideIncomingSurface(DesktopWindowState state) {
  if (state.userIsLooking) return NotificationSurface.inApp;
  if (state.ballEnabled) return NotificationSurface.bubble;
  return NotificationSurface.toast;
}

/// 是否需要用悬浮球承载整条流程（询问 → 进度 → 完成）。
///
/// 气泡和桌面卡片是两条互斥的呈现通道：一旦选定，进度与完成态必须留在同一条
/// 通道上，否则用户会在"球旁边一个、屏幕角落一个"之间反复跳。
bool useBallFlow(NotificationSurface surface) =>
    surface == NotificationSurface.bubble;
