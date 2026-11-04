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

/// 缓动：两端导数都为 0，用来做"把手 ⇄ 球"的形态切换，
/// 收尾时不会"啪"地停住。
func wispSmoothStep(_ x: CGFloat) -> CGFloat {
  let t = max(0, min(1, x))
  return t * t * (3 - 2 * t)
}

// MARK: - 通知卡 / 气泡的内容视图

/// 一张卡片的全部内容：底盘、图标、标题、正文、按钮或进度条。
///
/// 桌面通知卡和悬浮球气泡共用这一个视图——它们在两个平台上都是同一张卡，
/// 只是出现的位置不同。绘制逻辑只允许有一处。
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

  /// 迷你图标：青绿渐变圆角卡 + 两条白线 + 珊瑚圆点，与应用图标同构。
  private func drawIcon(in rect: NSRect) {
    let path = NSBezierPath(roundedRect: rect,
                            xRadius: rect.height * 0.30,
                            yRadius: rect.height * 0.30)
    NSGradient(starting: WispInk.brandLight, ending: WispInk.brand)?.draw(in: path, angle: 90)

    let s = rect.height
    NSColor.white.withAlphaComponent(0.92).setFill()
    for i in 0..<2 {
      let w = s * (i == 0 ? 0.50 : 0.34)
      let y = rect.minY + s * (0.52 + CGFloat(i) * 0.16)
      let bar = NSRect(x: rect.minX + s * 0.22, y: y,
                       width: w, height: s * 0.085)
      NSBezierPath(roundedRect: bar,
                   xRadius: s * 0.0425, yRadius: s * 0.0425).fill()
    }
    let d = s * 0.20
    WispInk.coral.setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.minX + s * 0.66,
                                y: rect.minY + s * 0.14,
                                width: d, height: d)).fill()
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

// MARK: - 卡片宿主（通知卡与气泡共用的"窗口 + 计时器 + 代次"）

/// 一个浮层通道（通知卡或气泡）的完整生命周期。
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

// MARK: - 悬浮球视图

/// 悬浮球 / 把手。
///
/// 窗口大小就是可见形状的大小（不留透明内边距）：macOS 的透明窗口边界依然
/// 会挡住下面的点击，窗口比图形大的话，球周围会出现一圈"点不动"的死区。
final class WispBallView: NSView {
  /// 0 = 贴在屏幕边上的把手，1 = 完整的球。
  var level: CGFloat = 1
  /// 吸附边：0 左 / 1 右 / 2 上 / 3 下。
  var edge: Int = 1

  var onHover: ((Bool) -> Void)?
  var onClick: (() -> Void)?
  var onDragBegan: (() -> Void)?
  /// 相对按下时的位移（屏幕坐标，y 向上）。
  var onDragDelta: ((CGFloat, CGFloat) -> Void)?
  var onDragEnded: (() -> Void)?

  private var dragOrigin: NSPoint = .zero
  private var didDrag = false
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let old = tracking { removeTrackingArea(old) }
    // activeAlways：应用不是前台时也必须收到进出事件，
    // 否则"鼠标移上去展开"只在 Wisp 是当前 App 时才灵。
    let area = NSTrackingArea(rect: .zero,
                              options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                              owner: self,
                              userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    onHover?(true)
  }

  override func mouseExited(with event: NSEvent) {
    onHover?(false)
  }

  override func mouseDown(with event: NSEvent) {
    dragOrigin = NSEvent.mouseLocation
    didDrag = false
    onDragBegan?()
  }

  override func mouseDragged(with event: NSEvent) {
    let now = NSEvent.mouseLocation
    let dx = now.x - dragOrigin.x
    let dy = now.y - dragOrigin.y
    if abs(dx) > 3 || abs(dy) > 3 { didDrag = true }
    if didDrag { onDragDelta?(dx, dy) }
  }

  override func mouseUp(with event: NSEvent) {
    if didDrag {
      onDragEnded?()
    } else {
      onClick?()
    }
    didDrag = false
  }

  override func draw(_ dirtyRect: NSRect) {
    let dark = WispInk.isDark(effectiveAppearance)
    let t = max(0, min(1, level))
    let w = bounds.width
    let h = bounds.height
    let radius = min(w, h) / 2

    // 白色底盘只在接近"球"的形态时出现；把手状态是纯青色药丸。
    let plateP = wispSmoothStep(t / 0.20)
    if plateP > 0.004 {
      WispInk.card(dark).withAlphaComponent(plateP).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    // 青色核心：从整块药丸连续变成图标里的那张小卡。
    let coreP = max(0, min(1, (t - 0.05) / 0.85))
    let side = min(w, h) * 0.34
    let iconRect = NSRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
    let core = NSRect(x: bounds.minX + (iconRect.minX - bounds.minX) * coreP,
                      y: bounds.minY + (iconRect.minY - bounds.minY) * coreP,
                      width: w + (iconRect.width - w) * coreP,
                      height: h + (iconRect.height - h) * coreP)
    let coreRadius = radius + (side * 0.24 - radius) * coreP
    let coreColor = WispInk.brand.blended(withFraction: coreP, of: WispInk.brandLight) ?? WispInk.brand
    coreColor.setFill()
    NSBezierPath(roundedRect: core, xRadius: coreRadius, yRadius: coreRadius).fill()

    // 两条白线 + 珊瑚点：只有长成"球"了才有意义。
    if coreP > 0.35 {
      let a = (coreP - 0.35) / 0.65
      NSColor.white.withAlphaComponent(0.92 * a).setFill()
      let barH = core.height * 0.13
      for i in 0..<2 {
        let bw = core.width * (i == 0 ? 0.66 : 0.44)
        let bar = NSRect(x: core.minX + core.width * 0.17,
                         y: core.minY + core.height * (i == 0 ? 0.30 : 0.52),
                         width: bw, height: barH)
        NSBezierPath(roundedRect: bar, xRadius: barH / 2, yRadius: barH / 2).fill()
      }
    }
    if coreP > 0.75 {
      let a = (coreP - 0.75) / 0.25
      let d = core.width * 0.17
      WispInk.coral.withAlphaComponent(a).setFill()
      NSBezierPath(ovalIn: NSRect(x: core.maxX - core.width * 0.16 - d,
                                  y: core.minY + core.height * 0.12,
                                  width: d, height: d)).fill()
    }
  }
}

// MARK: - 浮层总控

/// macOS 的桌面浮层：通知卡、悬浮球、气泡。
///
/// 由 `MainFlutterWindow` 的 `wisp/desktop` 通道驱动，语义与 Windows 侧完全
/// 等价（同一批方法名、同一套事件名）。这里不做任何业务判断——什么时候弹、
/// 弹哪一种，全部由 Dart 的 `decideIncomingSurface` 决定。
final class WispOverlay {
  static let shared = WispOverlay()

  /// 往 Dart 抛事件（onBallClicked / onBubbleAction / onToastClicked / ...）。
  var eventSink: ((String, [String: Any]) -> Void)?

  private let toast = WispCardHost()
  private let bubble = WispCardHost()

  private var ballPanel: WispOverlayPanel?
  private var ballView: WispBallView?
  private var ballEnabled = false
  private var ballSnapped = false
  private var ballEdge = 1
  private var ballLevel: CGFloat = 1
  private var ballCenter: NSPoint = .zero

  private let ballDisc: CGFloat = 66
  private let handleThick: CGFloat = 13
  private let handleLength: CGFloat = 46

  private var levelTimer: Timer?
  private var levelStart: CFTimeInterval = 0
  private var levelFrom: CGFloat = 1
  private var levelTo: CGFloat = 1
  private var levelSeconds: CGFloat = 0.3

  private var pulseTimer: Timer?
  private var pulseStart: CFTimeInterval = 0

  private var idleTimer: Timer?
  private var hoverTimer: Timer?
  private var hoverDelay: TimeInterval = 0.3
  private var hovered = false

  private var dragStartFrame: NSRect = .zero

  private init() {
    toast.onAction = { [weak self] action in self?.cardAction(self?.toast, action) }
    toast.onBodyTap = { [weak self] in self?.cardBodyTap(self?.toast) }
    bubble.onAction = { [weak self] action in self?.cardAction(self?.bubble, action) }
    bubble.onBodyTap = { [weak self] in self?.cardBodyTap(self?.bubble) }
    bubble.onTimeout = { [weak self] in self?.eventSink?("onBubbleTimeout", [:]) }
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

  private func frameIsUsable(_ frame: NSRect) -> Bool {
    for screen in NSScreen.screens {
      let hit = screen.frame.intersection(frame)
      if hit.width >= 24 && hit.height >= 24 { return true }
    }
    return false
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

  // MARK: 气泡

  func showBubble(_ title: String, body: String, mode: Int, progress: String) {
    let size = WispCardMetrics.panelSize
    bubble.show(title: title, body: body, mode: mode, progress: progress,
                frame: bubbleFrame(size))
  }

  func updateBubble(_ body: String, mode: Int, progress: String) {
    bubble.update(body: body, mode: mode, progress: progress)
  }

  func hideBubble() {
    bubble.hide()
  }

  /// 气泡的位置：优先放在"远离屏幕边缘"的那一侧，放不下就翻边。
  /// 没有悬浮球时退化成右下角。
  private func bubbleFrame(_ size: NSSize) -> NSRect {
    let area = workArea
    let gap: CGFloat = 12
    var x: CGFloat
    var y: CGFloat

    if ballEnabled, let panel = ballPanel, panel.isVisible {
      let b = panel.frame
      let edge = ballSnapped ? ballEdge : (b.midX < area.midX ? 0 : 1)
      if edge <= 1 {
        let toRight = (edge == 0)
        x = toRight ? b.maxX + gap : b.minX - size.width - gap
        if x + size.width > area.maxX { x = b.minX - size.width - gap }
        if x < area.minX { x = b.maxX + gap }
        y = b.midY - size.height / 2
      } else {
        let below = (edge == 2)          // 贴顶 → 气泡挂在下面
        y = below ? b.minY - size.height - gap : b.maxY + gap
        if y < area.minY { y = b.maxY + gap }
        if y + size.height > area.maxY { y = b.minY - size.height - gap }
        x = b.midX - size.width / 2
      }
    } else {
      x = area.maxX - size.width - 16
      y = area.minY + 16
    }

    x = min(max(x, area.minX), area.maxX - size.width)
    y = min(max(y, area.minY), area.maxY - size.height)
    return NSRect(x: x, y: y, width: size.width, height: size.height)
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

  // MARK: 悬浮球

  var ballState: (enabled: Bool, expanded: Bool, snapped: Bool) {
    let visible = ballEnabled && (ballPanel?.isVisible ?? false)
    return (visible, ballLevel > 0.9, ballSnapped)
  }

  var ballDimLevel: Double {
    Double(ballPanel?.alphaValue ?? 1)
  }

  func setFloatingBall(enabled: Bool, hoverDelayMs: Int, savedPos: NSPoint?,
                       savedSnapped: Bool, savedEdge: Int) {
    hoverDelay = max(0.05, Double(hoverDelayMs) / 1000.0)

    guard enabled else {
      ballEnabled = false
      stopBallTimers()
      ballPanel?.orderOut(nil)
      return
    }

    let panel = ensureBallPanel()
    ballEdge = (0...3).contains(savedEdge) ? savedEdge : 1
    ballSnapped = savedSnapped && (0...3).contains(savedEdge)

    var center: NSPoint
    if let pos = savedPos {
      center = NSPoint(x: pos.x + ballDisc / 2, y: pos.y + ballDisc / 2)
    } else {
      let area = workArea
      center = NSPoint(x: area.maxX - ballDisc / 2 - 12, y: area.midY)
    }
    if !frameIsUsable(NSRect(x: center.x - ballDisc / 2, y: center.y - ballDisc / 2,
                             width: ballDisc, height: ballDisc)) {
      // 上次的位置落在已经拔掉的显示器上：回到主屏右侧，别把球丢在屏幕外。
      let area = workArea
      center = NSPoint(x: area.maxX - ballDisc / 2 - 12, y: area.midY)
      ballSnapped = false
    }
    ballCenter = center
    ballEnabled = true
    ballLevel = ballSnapped ? 0 : 1
    panel.alphaValue = 1
    layoutBall()
    panel.invalidateShadow()
    panel.orderFrontRegardless()
    scheduleIdleDim()
  }

  func showBallAlert() {
    guard ballEnabled else { return }
    ballPanel?.alphaValue = 1
    idleTimer?.invalidate()
    idleTimer = nil
    if ballSnapped && ballLevel < 0.99 {
      animateLevel(to: 1, seconds: 0.26)
    }
    startPulse()
    scheduleIdleDim()
  }

  func collapseBall() {
    guard ballEnabled else { return }
    if ballSnapped {
      animateLevel(to: 0, seconds: 0.30)
    }
    scheduleIdleDim()
  }

  private func ensureBallPanel() -> WispOverlayPanel {
    if let panel = ballPanel { return panel }
    let panel = WispOverlayPanel(contentRect: NSRect(x: 0, y: 0, width: ballDisc, height: ballDisc),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
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

    let view = WispBallView(frame: NSRect(x: 0, y: 0, width: ballDisc, height: ballDisc))
    view.onHover = { [weak self] inside in self?.ballHover(inside) }
    view.onClick = { [weak self] in self?.ballClicked() }
    view.onDragBegan = { [weak self] in
      guard let self = self else { return }
      self.dragStartFrame = self.ballPanel?.frame ?? .zero
      self.stopPulse()
    }
    view.onDragDelta = { [weak self] dx, dy in
      guard let self = self, let panel = self.ballPanel else { return }
      panel.setFrameOrigin(NSPoint(x: self.dragStartFrame.origin.x + dx,
                                   y: self.dragStartFrame.origin.y + dy))
    }
    view.onDragEnded = { [weak self] in self?.ballDragEnded() }
    panel.contentView = view

    ballPanel = panel
    ballView = view
    return panel
  }

  /// 形状尺寸：0 是把手，1 是正圆。竖向边缘的球，把手是竖着的一条。
  private func shapeSize(_ level: CGFloat) -> NSSize {
    let vertical = ballEdge <= 1
    let across = handleThick + (ballDisc - handleThick) * level
    let along = handleLength + (ballDisc - handleLength) * level
    return vertical ? NSSize(width: across, height: along)
                    : NSSize(width: along, height: across)
  }

  /// 摆位：吸附时贴住那条边，自由状态以 ballCenter 为中心。
  /// scale 只给"心跳"动画用（1.0 = 正常大小）。
  private func layoutBall(scale: CGFloat = 1) {
    guard let panel = ballPanel else { return }
    let base = shapeSize(ballLevel)
    let w = (base.width * scale).rounded()
    let h = (base.height * scale).rounded()
    let area = workArea

    var x: CGFloat
    var y: CGFloat
    if ballSnapped {
      switch ballEdge {
      case 0: x = area.minX
      case 1: x = area.maxX - w
      default: x = ballCenter.x - w / 2
      }
      switch ballEdge {
      case 2: y = area.maxY - h
      case 3: y = area.minY
      default: y = ballCenter.y - h / 2
      }
    } else {
      x = ballCenter.x - w / 2
      y = ballCenter.y - h / 2
    }

    panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: w, height: h),
                   display: true)
    ballView?.level = ballLevel
    ballView?.edge = ballEdge
    ballView?.needsDisplay = true
  }

  // MARK: 球的动画与状态

  private func animateLevel(to target: CGFloat, seconds: CGFloat) {
    levelTimer?.invalidate()
    levelFrom = ballLevel
    levelTo = target
    levelSeconds = max(0.01, seconds)
    levelStart = CFAbsoluteTimeGetCurrent()
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      self?.stepLevel()
    }
    RunLoop.main.add(timer, forMode: .common)
    levelTimer = timer
  }

  private func stepLevel() {
    let elapsed = CFAbsoluteTimeGetCurrent() - levelStart
    let p = CGFloat(elapsed) / levelSeconds
    if p >= 1 {
      ballLevel = levelTo
      levelTimer?.invalidate()
      levelTimer = nil
      layoutBall()
      // 形态定下来了再重算窗口阴影：动画期间每帧重算太贵，
      // 而最终形状必须和阴影对得上，否则边缘会留一圈脏影。
      ballPanel?.invalidateShadow()
      return
    }
    ballLevel = levelFrom + (levelTo - levelFrom) * wispSmoothStep(p)
    layoutBall()
  }

  private func startPulse() {
    stopPulse()
    pulseStart = CFAbsoluteTimeGetCurrent()
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      let t = CGFloat(CFAbsoluteTimeGetCurrent() - self.pulseStart) / 1.1
      if t >= 1 {
        self.stopPulse()
        self.layoutBall()
        return
      }
      // 两下"心跳"，幅度递减：|sin| 保证只会变大，不会缩到比球还小。
      let phase = Double(t) * Double.pi * 2
      let beat = CGFloat(abs(sin(phase)) * (1 - Double(t)))
      self.layoutBall(scale: 1 + 0.10 * beat)
    }
    RunLoop.main.add(timer, forMode: .common)
    pulseTimer = timer
  }

  private func stopPulse() {
    pulseTimer?.invalidate()
    pulseTimer = nil
  }

  private func ballHover(_ inside: Bool) {
    guard ballEnabled else { return }
    hovered = inside
    if inside {
      idleTimer?.invalidate()
      idleTimer = nil
      undim()
      // 收成把手的：悬停一小会儿再展开，避免鼠标扫过就"弹"出来。
      if ballSnapped && ballLevel < 0.01 {
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: hoverDelay, repeats: false) { [weak self] _ in
          guard let self = self, self.hovered else { return }
          self.animateLevel(to: 1, seconds: 0.26)
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
      }
    } else {
      hoverTimer?.invalidate()
      hoverTimer = nil
      // 鼠标离开 0.7s 后收回把手（吸附状态下才有"把手"这回事）。
      let timer = Timer(timeInterval: 0.7, repeats: false) { [weak self] _ in
        guard let self = self, !self.hovered, self.ballEnabled else { return }
        if self.ballSnapped { self.animateLevel(to: 0, seconds: 0.30) }
        self.scheduleIdleDim()
      }
      RunLoop.main.add(timer, forMode: .common)
      hoverTimer = timer
    }
  }

  private func ballClicked() {
    guard ballEnabled else { return }
    // 还收着的时候点一下 = 展开，而不是把主窗口拽出来（用户多半只是想看看它）。
    if ballSnapped && ballLevel < 0.99 {
      animateLevel(to: 1, seconds: 0.26)
      return
    }
    eventSink?("onBallClicked", [:])
  }

  private func ballDragEnded() {
    guard let panel = ballPanel else { return }
    let f = panel.frame
    let area = workArea
    ballCenter = NSPoint(x: f.midX, y: f.midY)

    let distances: [CGFloat] = [
      f.minX - area.minX,          // 0 左
      area.maxX - f.maxX,          // 1 右
      area.maxY - f.maxY,          // 2 上
      f.minY - area.minY,          // 3 下
    ]
    var best = -1
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for i in 0..<distances.count where distances[i] < bestDistance {
      bestDistance = distances[i]
      best = i
    }

    if best >= 0 && bestDistance < 32 {
      ballEdge = best
      ballSnapped = true
      // 贴边后留一会儿再收：用户往往紧接着就要点它。
      animateLevel(to: 1, seconds: 0.18)
    } else {
      ballSnapped = false
      ballLevel = 1
      layoutBall()
      panel.invalidateShadow()
    }

    eventSink?("onBallPosition", [
      "x": Int(f.origin.x.rounded()),
      "y": Int(f.origin.y.rounded()),
      "snapped": ballSnapped,
      "edge": ballEdge,
    ])
    scheduleIdleDim()
  }

  // MARK: 静置变淡

  /// 鼠标离开 1s 后开始淡，1s 淡到 25%——"在但不碍事"。
  private func scheduleIdleDim() {
    idleTimer?.invalidate()
    let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
      guard let self = self, self.ballEnabled, !self.hovered else { return }
      // 气泡正挂在球旁边时不淡：那时候球是"有话说"的状态。
      if self.bubble.status["visible"] as? Bool == true { return }
      self.dim()
    }
    RunLoop.main.add(timer, forMode: .common)
    idleTimer = timer
  }

  private func dim() {
    guard let panel = ballPanel else { return }
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 1.0
      panel.animator().alphaValue = 0.25
    }, completionHandler: nil)
  }

  private func undim() {
    guard let panel = ballPanel else { return }
    // 回来要"迅速"：0.12s，仍然是渐变，不会闪。
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.12
      panel.animator().alphaValue = 1
    }, completionHandler: nil)
  }

  private func stopBallTimers() {
    levelTimer?.invalidate(); levelTimer = nil
    pulseTimer?.invalidate(); pulseTimer = nil
    idleTimer?.invalidate(); idleTimer = nil
    hoverTimer?.invalidate(); hoverTimer = nil
  }

  // MARK: 自测 / 诊断

  var surfaceStatus: [String: Any] {
    ["toast": toast.status, "bubble": bubble.status]
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

    var out: [String: Any] = [
      "workLeft": Int(area.minX.rounded()),
      "workTop": Int((screenHeight - area.maxY).rounded()),
      "workRight": Int(area.maxX.rounded()),
      "workBottom": Int((screenHeight - area.minY).rounded()),
      "toast": rect(toast.panel.frame, visible: toast.active && toast.panel.isVisible),
      "bubble": rect(bubble.panel.frame, visible: bubble.active && bubble.panel.isVisible),
    ]
    if let panel = ballPanel {
      out["ball"] = rect(panel.frame, visible: ballEnabled && panel.isVisible)
    }
    return out
  }
}

extension Notification.Name {
  /// 点通知卡正文 → 把主窗口叫回来。由 MainFlutterWindow 监听。
  static let wispOverlayWantsMainWindow = Notification.Name("wisp.overlay.wantsMainWindow")
}
