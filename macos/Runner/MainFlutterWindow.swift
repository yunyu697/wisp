import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var statusItem: NSStatusItem?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    self.delegate = self
    installStatusItem()
    setupChannel(flutterViewController)
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
  }

  private func revealMainWindow() {
    NSApp.setActivationPolicy(.regular)
    makeKeyAndOrderFront(self)
    NSApp.activate(ignoringOtherApps: true)
    setFlashing(false)
  }

  // MARK: - 菜单栏图标

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = item.button else {
      statusItem = nil
      return
    }
    button.image = Self.menuBarImage(alert: false)

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

  /// 菜单栏图标：正常态传输圆圈，提醒态叹号 + 红色。
  /// SF Symbol 天然适配菜单栏明暗；老系统拿应用图标缩尺寸兜底。
  private static func menuBarImage(alert: Bool) -> NSImage? {
    if #available(macOS 11.0, *) {
      let name = alert ? "exclamationmark.circle" : "arrow.up.arrow.down.circle"
      if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Wisp") {
        return image
      }
    }
    guard let icon = NSApp.applicationIconImage.copy() as? NSImage else { return nil }
    icon.size = NSSize(width: 18, height: 18)
    return icon
  }

  /// 有新传输请求时菜单栏图标变红提醒（对应 Dart 侧 setTrayFlashing）。
  private func setFlashing(_ on: Bool) {
    guard let button = statusItem?.button else { return }
    button.image = Self.menuBarImage(alert: on)
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
  /// 没实现的方法照旧回 FlutterMethodNotImplemented，Dart 侧会静默忽略，
  /// 所以悬浮球之类没有 macOS 形态的能力不影响主流程。
  private func setupChannel(_ controller: FlutterViewController) {
    let messenger = controller.engine.binaryMessenger
    let channel = FlutterMethodChannel(name: "wisp/desktop", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "showWindow":
        // 托盘/菜单栏点击唤回主窗口。
        self.revealMainWindow()
        result(true)
      case "windowState":
        // 通知分流要的两维：主窗口可见 + 是否正被使用。
        // 窗口可见但用户在别的应用里（isActive=false）时，应用内弹层看不见。
        let visible = self.isVisible
        let active = visible && self.isKeyWindow && NSApp.isActive
        result([
          "visible": visible,
          "active": active,
          "ballEnabled": false,
          "ballExpanded": false,
          "ballSnapped": false
        ])
      case "isWindowVisible":
        result(self.isVisible)
      case "isSupported":
        // 桌面驻留能力存在（菜单栏图标）。
        result(true)
      case "setTrayFlashing":
        let args = call.arguments as? [String: Any]
        let enabled = args?["enabled"] as? Bool ?? false
        self.setFlashing(enabled)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
