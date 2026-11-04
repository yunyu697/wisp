import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var statusItem: NSStatusItem?
  private var channel: FlutterMethodChannel?
  private var lastReportedVisible: Bool?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    self.delegate = self
    installStatusItem()
    setupOverlay()
    setupChannel(flutterViewController)
  }

  // MARK: - 桌面浮层

  /// 通知卡 / 悬浮球 / 气泡（见 WispOverlay.swift）。
  ///
  /// 之前 macOS 完全没有这套东西：通道里没有对应方法，Dart 调用静默失败，
  /// 设置页只能把这个开关藏起来。关掉窗口驻留菜单栏之后"收到文件没有任何
  /// 提示"就成了最影响日常的问题，所以这里补齐与 Windows 对等的能力。
  private func setupOverlay() {
    let overlay = WispOverlay.shared
    overlay.eventSink = { [weak self] name, args in
      self?.channel?.invokeMethod(name, arguments: args)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(overlayWantsMainWindow),
      name: .wispOverlayWantsMainWindow,
      object: nil)
  }

  @objc private func overlayWantsMainWindow() {
    WispOverlay.shared.hideToast()
    revealMainWindow()
  }

  // MARK: - 关窗 -> 菜单栏驻留

  /// 关窗不再等于退出：接收服务要一直跑着才有意义。
  ///
  /// 窗口真关闭后把应用切成 accessory（Dock 图标消失——用户原话"没有必要"），
  /// 入口交给菜单栏图标。从菜单栏"打开 Wisp"时切回 regular 并前置主窗口。
  ///
  /// 退出路径不受影响：Cmd+Q / 菜单栏「退出」走 terminate，与这里无关；
  /// 让退出行为成立的是 AppDelegate 里
  /// applicationShouldTerminateAfterLastWindowClosed = false。
  func windowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    reportWindowVisibility(false)
  }

  /// 最小化也算"用户看不见"：窗口还在、引擎还在出帧，但屏幕上没有它。
  /// 主界面那圈雷达是无限动画，没人看还照画会白吃 CPU。
  func windowDidMiniaturize(_ notification: Notification) {
    reportWindowVisibility(false)
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    reportWindowVisibility(isVisible)
  }

  func windowDidBecomeKey(_ notification: Notification) {
    reportWindowVisibility(true)
  }

  private func reportWindowVisibility(_ visible: Bool) {
    if lastReportedVisible == visible { return }
    lastReportedVisible = visible
    channel?.invokeMethod("onWindowVisibility", arguments: ["visible": visible])
  }

  private func revealMainWindow() {
    NSApp.setActivationPolicy(.regular)
    makeKeyAndOrderFront(self)
    NSApp.activate(ignoringOtherApps: true)
    setFlashing(false)
    reportWindowVisibility(true)
    // Dart 侧据此把桌面提醒退场：用户已经回到主窗口，后续进度在界面里看。
    channel?.invokeMethod("onWindowRestored", arguments: nil)
  }

  // MARK: - 菜单栏图标

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = item.button else {
      statusItem = nil
      return
    }
    button.image = Self.menuBarImage()
    button.imagePosition = .imageOnly
    // 图标按自身 20pt 画，别再让按钮二次压缩（默认就是这么设的，写明防误改）。
    button.imageScaling = .scaleProportionallyDown
    button.toolTip = "Wisp — 局域网传输"

    let menu = NSMenu()
    let open = NSMenuItem(title: "打开 Wisp", action: #selector(openFromMenuBar), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "退出 Wisp", action: #selector(quitFromMenuBar), keyEquivalent: "")
    quit.target = self
    menu.addItem(quit)
    item.menu = menu

    statusItem = item
  }

  /// 菜单栏图标：把应用图标（青绿卡片 + 两条白线 + 珊瑚圆点）压成单色模板版。
  ///
  /// 以前用 SF Symbol 的 `arrow.up.arrow.down.circle`：它跟应用图标毫无关系，
  /// 细线条 + 大留白，放在菜单栏里又小又认不出。这里按应用图标自己的构图重画：
  /// 实心圆角卡片（=那张文件卡）+ 两条挖空的白线 + 右上角独立圆点（=珊瑚点）。
  /// 模板图交给系统着色，深浅色菜单栏都自动适配，提醒态只需要换 tint。
  ///
  /// 尺寸：画布 20pt、内容几乎画满（bbox 18×18）。
  /// 早先的 18pt 版里实心卡片只有 11.7×11.8，四周还留着大片空白，
  /// 摆在一排系统图标中间明显偏小、不协调——菜单栏图标的分量主要来自
  /// 实心块的面积，而不是外框大小，所以这里把卡片直接放大到 15.2×14.0。
  ///
  /// 用 drawingHandler 而不是预渲染位图：Retina 上按 2x 重新光栅化，
  /// 不会像「把 1024 缩到 20」那样糊成一团。
  private static func menuBarImage() -> NSImage {
    let side: CGFloat = 20
    let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
      // 设计稿按 20×20 画，这里等比缩放（外部若改 side，图形跟着走）。
      let u = side / 20.0

      // 卡片（= 应用图标里那张文件卡）
      let card = NSRect(x: 1.0 * u, y: 5.0 * u, width: 15.2 * u, height: 14.0 * u)
      NSColor.black.setFill()
      NSBezierPath(roundedRect: card, xRadius: 4.2 * u, yRadius: 4.2 * u).fill()

      // 两条白线 + 右上角圆点：模板图用 alpha 当遮罩，所以这里是"挖空"
      // （clear 混合），不是画白色——画白色在深色菜单栏里会变成实心块。
      //
      // 圆点必须与卡片上沿相切（同一 y），不能压进卡片：clear 会把卡片
      // 咬掉一块，变成一个洞。
      guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
      ctx.setBlendMode(.clear)
      let bars: [(CGFloat, CGFloat, CGFloat)] = [
        (8.0, 11.7, 2.2),   // (y, 长度, 粗细)
        (14.0, 6.4, 2.2),
      ]
      for (y, length, thick) in bars {
        let bar = NSRect(x: 3.75 * u, y: y * u, width: length * u, height: thick * u)
        NSBezierPath(roundedRect: bar, xRadius: thick * u / 2,
                     yRadius: thick * u / 2).fill()
      }
      NSBezierPath(ovalIn: NSRect(x: 15.0 * u, y: 1.0 * u,
                                  width: 4.0 * u, height: 4.0 * u)).fill()
      ctx.setBlendMode(.normal)
      return true
    }
    image.isTemplate = true
    return image
  }

  /// 有新传输请求时菜单栏图标变红提醒（对应 Dart 侧 setTrayFlashing）。
  /// 图形不变、只换 tint：同一个标志物换个颜色，比换成另一个图标更好认。
  private func setFlashing(_ on: Bool) {
    guard let button = statusItem?.button else { return }
    if button.image == nil { button.image = Self.menuBarImage() }
    button.contentTintColor = on ? NSColor.systemRed : nil
  }

  @objc private func openFromMenuBar() {
    revealMainWindow()
  }

  @objc private func quitFromMenuBar() {
    NSApp.terminate(nil)
  }

  // MARK: - 平台通道（wisp/desktop）

  /// Windows 侧这套通道已有完整实现；macOS 这里补齐对等语义。
  ///
  /// 服务守护（SCM）、托盘闪烁之外的 Windows 专有能力仍然回
  /// FlutterMethodNotImplemented，Dart 侧会静默忽略；设置页也按平台隐藏了
  /// 对应开关，不会出现"点了没反应"的按钮。
  private func setupChannel(_ controller: FlutterViewController) {
    let messenger = controller.engine.binaryMessenger
    let channel = FlutterMethodChannel(name: "wisp/desktop", binaryMessenger: messenger)
    self.channel = channel
    let overlay = WispOverlay.shared

    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(nil)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      let mode = args["mode"] as? Int ?? 0
      let progress = args["progress"] as? String ?? ""
      let title = args["title"] as? String ?? ""
      let body = args["body"] as? String ?? ""

      switch call.method {
      case "showWindow":
        // 托盘/菜单栏点击唤回主窗口（顺手收掉通知卡）。
        self.overlayWantsMainWindow()
        result(true)
      case "windowState":
        // 通知分流要的两维：主窗口可见 + 是否正被使用。
        // 窗口可见但用户在别的应用里（isActive=false）时，应用内弹层看不见。
        let ball = overlay.ballState
        let visible = self.isVisible && !self.isMiniaturized
        let active = visible && self.isKeyWindow && NSApp.isActive
        result([
          "visible": visible,
          "active": active,
          "ballEnabled": ball.enabled,
          "ballExpanded": ball.expanded,
          "ballSnapped": ball.snapped,
        ])
      case "isWindowVisible":
        result(self.isVisible && !self.isMiniaturized)
      case "isSupported":
        // 桌面驻留能力存在（菜单栏图标 + 桌面浮层）。
        result(true)
      case "setTrayFlashing":
        self.setFlashing(args["enabled"] as? Bool ?? false)
        result(nil)
      case "setFloatingBall":
        var pos: NSPoint?
        if let x = args["x"] as? Int, let y = args["y"] as? Int {
          pos = NSPoint(x: x, y: y)
        }
        overlay.setFloatingBall(
          enabled: args["enabled"] as? Bool ?? false,
          hoverDelayMs: args["hoverDelayMs"] as? Int ?? 300,
          savedPos: pos,
          savedSnapped: args["snapped"] as? Bool ?? false,
          savedEdge: args["edge"] as? Int ?? -1)
        result(nil)
      case "showBallAlert":
        overlay.showBallAlert()
        result(nil)
      case "collapseBall":
        overlay.collapseBall()
        result(nil)
      case "showToast":
        overlay.showToast(title, body: body, mode: mode, progress: progress)
        result(nil)
      case "updateToast":
        overlay.updateToast(body, mode: mode, progress: progress)
        result(nil)
      case "hideToast":
        overlay.hideToast()
        result(nil)
      case "showBubble":
        overlay.showBubble(title, body: body, mode: mode, progress: progress)
        result(nil)
      case "updateBubble":
        overlay.updateBubble(body, mode: mode, progress: progress)
        result(nil)
      case "hideBubble":
        overlay.hideBubble()
        result(nil)
      case "surfaceStatus":
        // Dart 靠这个确认"发出去的通知真的画出来了"，没出来会重发。
        result(overlay.surfaceStatus)
      case "debugWindows":
        result(overlay.windowsDebug)
      case "debugBallDim":
        result(overlay.ballDimLevel)
      case "debugSetMainVisible":
        if args["visible"] as? Bool ?? true {
          self.revealMainWindow()
        } else {
          self.orderOut(nil)
          self.reportWindowVisibility(false)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
