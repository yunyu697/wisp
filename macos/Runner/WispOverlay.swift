import Cocoa

// MARK: - 设计常量
//
// 这里的数值全部照抄 Windows 侧 `windows/runner/flutter_window.cpp` 的
// kCardWidth / kCardHeight / kCardMargin / kCardMode*。两个平台的通知卡
// 必须是同一张卡——用户切换设备时不该看到两种排版。

/// 卡片模式。数值与 Dart 的 `DesktopService.bubbleAsk/Progress/Done/Canceled`
/// 以及 C++ 的 `kCardMode*` 一一对应，**不能改数值**。
enum WispCardMode {
  static let ask = 0
  static let progress = 1
  static let done = 2
  /// 取消/中断提示与"纯消息通知"共用这个模式：只有标题和正文，
  /// 没有按钮、没有进度条，3 秒后自己收。
  static let canceled = 3
}

enum WispCardMetrics {
  static let width: CGFloat = 340
  static let height: CGFloat = 132
  static let margin: CGFloat = 16
  static let radius: CGFloat = 18
  static let icon: CGFloat = 44
  static let buttonHeight: CGFloat = 32
  static var panelSize: NSSize {
    NSSize(width: width + margin * 2, height: height + margin * 2)
  }
}

// MARK: - 调色板

/// 与 `lib/core/design/app_colors.dart` 的 WispColors 逐值对齐，
/// 也与 Windows 侧 kBrand/kAccent 一致。改色必须三处同时改。
enum WispInk {
  static let brand = NSColor(srgbRed: 14.0 / 255.0, green: 124.0 / 255.0,
                             blue: 134.0 / 255.0, alpha: 1)
  static let brandLight = NSColor(srgbRed: 58.0 / 255.0, green: 200.0 / 255.0,
                                  blue: 203.0 / 255.0, alpha: 1)
  static let coral = NSColor(srgbRed: 255.0 / 255.0, green: 122.0 / 255.0,
                             blue: 89.0 / 255.0, alpha: 1)

  static func isDark(_ appearance: NSAppearance) -> Bool {
    return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }

  static func card(_ dark: Bool) -> NSColor {
    return dark
      ? NSColor(srgbRed: 0.145, green: 0.153, blue: 0.157, alpha: 1)
      : .white
  }

  static func text(_ dark: Bool) -> NSColor {
    return dark
      ? NSColor(srgbRed: 0.945, green: 0.945, blue: 0.937, alpha: 1)
      : NSColor(srgbRed: 23.0 / 255.0, green: 25.0 / 255.0, blue: 26.0 / 255.0, alpha: 1)
  }

  static func subText(_ dark: Bool) -> NSColor {
    return dark
      ? NSColor(srgbRed: 0.647, green: 0.663, blue: 0.659, alpha: 1)
      : NSColor(srgbRed: 107.0 / 255.0, green: 113.0 / 255.0, blue: 112.0 / 255.0, alpha: 1)
  }

  static func chip(_ dark: Bool) -> NSColor {
    return dark
      ? NSColor(srgbRed: 0.204, green: 0.212, blue: 0.212, alpha: 1)
      : NSColor(srgbRed: 237.0 / 255.0, green: 235.0 / 255.0, blue: 228.0 / 255.0, alpha: 1)
  }

  static func line(_ dark: Bool) -> NSColor {
    return dark
      ? NSColor(srgbRed: 0.259, green: 0.267, blue: 0.267, alpha: 1)
      : NSColor(srgbRed: 229.0 / 255.0, green: 226.0 / 255.0, blue: 218.0 / 255.0, alpha: 1)
  }
}

// MARK: - 桌面通知卡的内容视图

/// 一张卡片的全部内容：底盘、图标、标题、正文、按钮或进度条。
///
/// 桌面通知卡专用视图：绘制逻辑只允许有一处（与 Windows 侧同一张卡）。
final class WispCardView: NSView {
  var title: String = ""
  var bodyText: String = ""
  var progress: String = ""
  var mode: Int = WispCardMode.ask

  /// 点了主按钮/次按钮：accept / dismiss / openFolder / close。
  var onAction: ((String) -> Void)?
  /// 点了卡片其它位置（只有询问态和完成态会响，进度/提示态忽略点击）。
  var onBodyTap: (() -> Void)?

  private var primaryRect: NSRect = .zero
  private var secondaryRect: NSRect = .zero

  /// 翻转坐标系：这样所有 y 都能照着 Windows 那份（y 向下）的布局值写，
  /// 不用在脑子里做两遍上下颠倒。
  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let dark = WispInk.isDark(effectiveAppearance)
    let m = WispCardMetrics.margin
    let card = NSRect(x: m, y: m,
                      width: bounds.width - m * 2,
                      height: bounds.height - m * 2)

    // 底盘。阴影交给窗口（panel.hasShadow）——窗口阴影是按 alpha 通道算的，
    // 自己再画一层会出现"双边框"。
    WispInk.card(dark).setFill()
    let path = NSBezierPath(roundedRect: card,
                            xRadius: WispCardMetrics.radius,
                            yRadius: WispCardMetrics.radius)
    path.fill()
    WispInk.line(dark).withAlphaComponent(0.5).setStroke()
    path.lineWidth = 0.5
    path.stroke()

    let iconRect = NSRect(x: card.minX + 16, y: card.minY + 18,
                          width: WispCardMetrics.icon, height: WispCardMetrics.icon)
    drawIcon(in: iconRect)

    let textX = iconRect.maxX + 14
    let textW = card.maxX - 16 - textX

    drawText(title,
             in: NSRect(x: textX, y: card.minY + 16, width: textW, height: 22),
             font: NSFont.systemFont(ofSize: 15, weight: .semibold),
             color: WispInk.text(dark), align: .left, lines: 1)
    drawText(bodyText,
             in: NSRect(x: textX, y: card.minY + 44, width: textW, height: 42),
             font: NSFont.systemFont(ofSize: 12.5),
             color: WispInk.subText(dark), align: .left, lines: 2)

    primaryRect = .zero
    secondaryRect = .zero

    // "看完就走"的提示卡：没有按钮、没有进度条，3 秒自动收。
    if mode == WispCardMode.canceled { return }

    let buttonY = card.maxY - WispCardMetrics.buttonHeight - 14

    if mode == WispCardMode.progress {
      let bar = NSRect(x: textX, y: buttonY + 8, width: textW, height: 8)
      WispInk.chip(dark).setFill()
      NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
      let ratio = progressRatio()
      if ratio > 0.02 {
        let fill = NSRect(x: bar.minX, y: bar.minY,
                          width: bar.width * ratio, height: bar.height)
        WispInk.brand.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
      }
      drawText(progress,
               in: NSRect(x: textX, y: bar.maxY + 4, width: textW, height: 18),
               font: NSFont.systemFont(ofSize: 11.5),
               color: WispInk.subText(dark), align: .center, lines: 1)
      return
    }

    let done = mode == WispCardMode.done
    let gap: CGFloat = 8
    let half = (textW - gap) / 2
    let primary = NSRect(x: textX + half + gap, y: buttonY,
                         width: half, height: WispCardMetrics.buttonHeight)
    let secondary = NSRect(x: textX, y: buttonY,
                           width: half, height: WispCardMetrics.buttonHeight)
    drawButton(primary, filled: true, label: done ? "打开目录" : "接收", dark: dark)
    drawButton(secondary, filled: false, label: done ? "关闭" : "忽略", dark: dark)
    primaryRect = primary
    secondaryRect = secondary
  }

  // MARK: 点击

  override func mouseDown(with event: NSEvent) {
    // 进度卡不可点（避免误触），提示卡也不需要交互。
    if mode == WispCardMode.progress || mode == WispCardMode.canceled { return }
    let pt = convert(event.locationInWindow, from: nil)
    // 窗口比卡片大一圈（给窗口阴影留的空隙）。点在透明空隙里什么也不该发生，
    // 否则"点了一下卡片旁边"就把主窗口叫出来了。
    let m = WispCardMetrics.margin
    let card = NSRect(x: m, y: m,
                      width: bounds.width - m * 2,
                      height: bounds.height - m * 2)
    guard card.contains(pt) else { return }
    let done = mode == WispCardMode.done
    if primaryRect.contains(pt) {
      onAction?(done ? "openFolder" : "accept")
      return
    }
    if secondaryRect.contains(pt) {
      onAction?(done ? "close" : "dismiss")
      return
    }
    onBodyTap?()
  }

  // MARK: 绘制细节

  /// 迷你图标：方案 C「不分彼此」——青绿 squircle 底 + 后置描边文件卡
  /// + 前置白色消息卡（带气泡尾）+ 两条青绿文字线 + 珊瑚圆点。
  /// 坐标按 assets/icon/wisp_icon.svg 的 1024 画布归一化；Windows 侧
  /// DrawMiniIcon 用同一组数字，改图标必须两处一起改。
  private func drawIcon(in rect: NSRect) {
    let s = min(rect.width, rect.height)
    let x = rect.minX + (rect.width - s) / 2
    let y = rect.minY + (rect.height - s) / 2
    func box(_ nx: CGFloat, _ ny: CGFloat,
             _ nw: CGFloat, _ nh: CGFloat) -> NSRect {
      NSRect(x: x + s * nx, y: y + s * ny, width: s * nw, height: s * nh)
    }

    // 底板：与 WispInk.brand / brandLight 同源的渐变。
    let bg = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: s, height: s),
                          xRadius: s * 0.235, yRadius: s * 0.235)
    NSGradient(starting: WispInk.brandLight, ending: WispInk.brand)?.draw(in: bg, angle: 90)

    // 后置文件卡：只描边、倾斜 -9°，别填白，否则两层白卡会糊成一块。
    let back = NSBezierPath(roundedRect: box(0.410, 0.180, 0.422, 0.445),
                            xRadius: s * 0.055, yRadius: s * 0.055)
    let cx = x + s * 0.617, cy = y + s * 0.406
    NSGraphicsContext.saveGraphicsState()
    let spin = NSAffineTransform()
    spin.translateX(by: cx, yBy: cy)
    spin.rotate(byDegrees: -9)
    spin.translateX(by: -cx, yBy: -cy)
    spin.concat()
    NSColor.white.withAlphaComponent(0.6).setStroke()
    back.lineWidth = s * 0.018
    back.lineJoinStyle = .round
    back.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // 前置消息卡 + 左下角实心气泡尾。
    NSColor.white.setFill()
    NSBezierPath(roundedRect: box(0.188, 0.406, 0.500, 0.360),
                 xRadius: s * 0.102, yRadius: s * 0.102).fill()
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: x + s * 0.293, y: y + s * 0.715))
    tail.line(to: NSPoint(x: x + s * 0.176, y: y + s * 0.855))
    tail.line(to: NSPoint(x: x + s * 0.305, y: y + s * 0.715))
    tail.close()
    tail.fill()

    // 卡内两条文字线用的是底板深青，不是白色。
    WispInk.brand.setFill()
    let bars: [(CGFloat, CGFloat)] = [(0.531, 0.320), (0.621, 0.100)]
    for (ny, nw) in bars {
      NSBezierPath(roundedRect: box(0.277, ny, nw, 0.047),
                   xRadius: s * 0.024, yRadius: s * 0.024).fill()
    }

    WispInk.coral.setFill()
    NSBezierPath(ovalIn: box(0.758, 0.188, 0.117, 0.117)).fill()
  }

  private func drawButton(_ rect: NSRect, filled: Bool, label: String, dark: Bool) {
    let path = NSBezierPath(roundedRect: rect,
                            xRadius: rect.height / 2,
                            yRadius: rect.height / 2)
    if filled {
      NSGradient(starting: WispInk.brandLight, ending: WispInk.brand)?.draw(in: path, angle: 90)
    } else {
      WispInk.chip(dark).setFill()
      path.fill()
    }
    let color = filled ? NSColor.white : WispInk.text(dark)
    let font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: style,
    ]
    let lineHeight = font.pointSize + 4
    let r = NSRect(x: rect.minX, y: rect.midY - lineHeight / 2,
                   width: rect.width, height: lineHeight)
    (label as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: attrs)
  }

  private func drawText(_ text: String, in rect: NSRect, font: NSFont,
                        color: NSColor, align: NSTextAlignment, lines: Int) {
    if text.isEmpty { return }
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
    let attrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: style,
    ]
    // truncatesLastVisibleLine：两行装不下时最后一行打省略号，
    // 而不是把字挤出卡片（Windows 那边也是这么处理的）。
    (text as NSString).draw(with: rect,
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                            attributes: attrs)
  }

  /// "72% · 3.4 MB/s" → 0.72。取不到就当 0（进度条空着也不会出错）。
  private func progressRatio() -> CGFloat {
    guard let pct = progress.firstIndex(of: "%") else { return 0 }
    let head = String(progress[progress.startIndex..<pct])
    guard let value = Double(head.trimmingCharacters(in: .whitespaces)) else { return 0 }
    return CGFloat(max(0, min(100, value)) / 100)
  }
}

// MARK: - 浮层面板

/// 不抢焦点的浮层窗口。
///
/// 三件套缺一不可：borderless（没有标题栏）、nonactivatingPanel（点它不会把
/// 应用激活、也不会让当前 App 失焦）、statusBar 层级（盖在普通窗口之上）。
final class WispOverlayPanel: NSPanel {
  override var canBecomeKey: Bool { return false }
  override var canBecomeMain: Bool { return false }
}

// MARK: - 通知卡宿主（窗口 + 计时器 + 代次）

/// 一张桌面通知卡的完整生命周期。
///
/// 这里最要紧的是**代次（generation）**：收起的淡出动画是异步的，如果在它
/// 还没走完时又弹了一张新的，淡出的完成回调会把新窗口 orderOut 掉——
/// 用户看到的就是"第一次不出现，第二次才有"。每条延迟动作都记住自己的代次，
/// 代次对不上就什么都不做。
final class WispCardHost {
  let panel: WispOverlayPanel
  let view: WispCardView

  private(set) var active = false
  private(set) var drawn = false
  private(set) var mode = WispCardMode.ask

  private var timeout: Timer?
  private var generation = 0

  var onAction: ((String) -> Void)?
  var onBodyTap: (() -> Void)?
  var onTimeout: (() -> Void)?

  init() {
    let size = WispCardMetrics.panelSize
    panel = WispOverlayPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
    view = WispCardView(frame: NSRect(origin: .zero, size: size))

    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovable = false
    panel.ignoresMouseEvents = false
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.contentView = view

    view.onAction = { [weak self] action in self?.onAction?(action) }
    view.onBodyTap = { [weak self] in self?.onBodyTap?() }
  }

  /// 当前是否真的在屏幕上、且内容已经画出来了。
  /// Dart 侧靠这两个值判断"发了到底有没有用"，只有一个为真都不算成功。
  var status: [String: Any] {
    let shown = active && panel.isVisible
    return ["visible": shown, "active": active, "drawn": shown && drawn]
  }

  func show(title: String, body: String, mode: Int, progress: String, frame: NSRect) {
    view.title = title
    view.bodyText = body
    view.progress = progress
    view.mode = mode
    self.mode = mode
    view.needsDisplay = true

    panel.setFrame(frame, display: false)
    // 先透明、显示、再画、最后淡入：动画丢帧最多让卡片淡一点，
    // 绝不会出现"窗口在、内容是空的"（这正是"第一次不出现"的老毛病）。
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    view.display()
    drawn = true
    active = true
    generation += 1

    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.16
      self.panel.animator().alphaValue = 1
    }, completionHandler: nil)

    scheduleTimeout(mode)
  }

  func update(body: String, mode: Int, progress: String) {
    // 用显式的 active 标志而不是 isVisible：窗口刚显示还没画完时 isVisible
    // 也不可靠，更新会被静默丢掉（进度条不动）。
    guard active else { return }
    view.bodyText = body
    view.progress = progress
    view.mode = mode
    self.mode = mode
    view.needsDisplay = true
    view.display()
    drawn = true
    scheduleTimeout(mode)
  }

  func hide(animated: Bool = true) {
    timeout?.invalidate()
    timeout = nil
    generation += 1
    let gen = generation

    guard active else {
      drawn = false
      if panel.isVisible { panel.orderOut(nil) }
      return
    }
    active = false
    drawn = false

    if !animated {
      panel.orderOut(nil)
      return
    }
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.14
      self.panel.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      guard let self = self else { return }
      // 代次对不上 = 期间又弹了新的，别把新窗口收掉。
      if self.generation == gen { self.panel.orderOut(nil) }
    })
  }

  /// 存活时间按模式分：询问 30s（用户要想一想）、进度/完成 8s（每次更新顺延）、
  /// 取消提示 3s（看完即走）。
  private func scheduleTimeout(_ mode: Int) {
    timeout?.invalidate()
    let seconds: TimeInterval = mode == WispCardMode.ask
      ? 30
      : (mode == WispCardMode.canceled ? 3 : 8)
    let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
      guard let self = self else { return }
      self.timeout = nil
      let fired = self.mode
      self.hide()
      // 取消提示的超时只是"看完自动收"，不算询问超时——否则 Dart 会
      // 误以为用户把询问晾过去了。
      if fired != WispCardMode.canceled { self.onTimeout?() }
    }
    RunLoop.main.add(timer, forMode: .common)
    timeout = timer
  }
}

// MARK: - 浮层总控

/// macOS 的桌面浮层：桌面通知卡（常驻悬浮球与贴球气泡已退役）。
///
/// 由 `MainFlutterWindow` 的 `wisp/desktop` 通道驱动，语义与 Windows 侧完全
/// 等价（同一批方法名、同一套事件名）。这里不做任何业务判断——什么时候弹、
/// 弹哪一种，全部由 Dart 的 `decideIncomingSurface` 决定。
final class WispOverlay {
  static let shared = WispOverlay()

  /// 往 Dart 抛事件（通知卡按钮 onBubbleAction / onToastClicked 等）。
  var eventSink: ((String, [String: Any]) -> Void)?

  private let toast = WispCardHost()

  private init() {
    toast.onAction = { [weak self] action in self?.cardAction(self?.toast, action) }
    toast.onBodyTap = { [weak self] in self?.cardBodyTap(self?.toast) }
  }

  // MARK: 屏幕

  /// 鼠标所在屏幕的可用区域（已扣掉菜单栏和 Dock）。
  private var workArea: NSRect {
    let mouse = NSEvent.mouseLocation
    for screen in NSScreen.screens where NSMouseInRect(mouse, screen.frame, false) {
      return screen.visibleFrame
    }
    return (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
  }

  // MARK: 通知卡

  func showToast(_ title: String, body: String, mode: Int, progress: String) {
    let size = WispCardMetrics.panelSize
    let area = workArea
    var x = area.maxX - size.width - 14
    var y = area.minY + 14
    x = max(area.minX, x)
    y = max(area.minY, y)
    toast.show(title: title, body: body, mode: mode, progress: progress,
               frame: NSRect(x: x, y: y, width: size.width, height: size.height))
  }

  func updateToast(_ body: String, mode: Int, progress: String) {
    toast.update(body: body, mode: mode, progress: progress)
  }

  func hideToast() {
    toast.hide()
  }

  // MARK: 卡片交互

  private func cardAction(_ host: WispCardHost?, _ action: String) {
    guard let host = host else { return }
    if action == "close" {
      host.hide()
      return
    }
    // 和 Windows 一致：先收卡片再回话，避免按钮还能被点第二次。
    host.hide()
    eventSink?("onBubbleAction", ["action": action])
  }

  private func cardBodyTap(_ host: WispCardHost?) {
    guard let host = host else { return }
    host.hide()
    // 点卡片正文 = "我要去处理它"：叫回主窗口，Dart 侧收到后桌面提醒退场。
    NotificationCenter.default.post(name: .wispOverlayWantsMainWindow, object: nil)
    eventSink?("onToastClicked", [:])
  }

  // MARK: 自测 / 诊断

  var surfaceStatus: [String: Any] {
    ["toast": toast.status]
  }

  /// 与 Windows 的 debugWindows 同构（y 也统一成"从屏幕顶往下"），
  /// 这样自测里"通知卡必须在工作区内"这类断言可以原样复用。
  var windowsDebug: [String: Any] {
    let area = workArea
    let screenHeight = NSScreen.screens.first(where: { $0.visibleFrame == area })?.frame.maxY
      ?? (NSScreen.main?.frame.maxY ?? 0)

    func rect(_ frame: NSRect, visible: Bool) -> [String: Any] {
      [
        "visible": visible,
        "left": Int(frame.minX.rounded()),
        "top": Int((screenHeight - frame.maxY).rounded()),
        "right": Int(frame.maxX.rounded()),
        "bottom": Int((screenHeight - frame.minY).rounded()),
      ]
    }

    let out: [String: Any] = [
      "workLeft": Int(area.minX.rounded()),
      "workTop": Int((screenHeight - area.maxY).rounded()),
      "workRight": Int(area.maxX.rounded()),
      "workBottom": Int((screenHeight - area.minY).rounded()),
      "toast": rect(toast.panel.frame, visible: toast.active && toast.panel.isVisible),
    ]
    return out
  }
}

extension Notification.Name {
  /// 点通知卡正文 → 把主窗口叫回来。由 MainFlutterWindow 监听。
  static let wispOverlayWantsMainWindow = Notification.Name("wisp.overlay.wantsMainWindow")
}
