import Cocoa

/// 主窗口的拖拽接收层：覆盖在 FlutterView 上方，专门接住从 Finder 拖来的文件。
///
/// ## 为什么可以"盖在上面但不挡点击"
///
/// macOS 的拖拽派发**不走 hitTest**：拖拽会话开始时，AppKit 直接枚举层
/// 里注册过 `registerForDraggedTypes` 的 view，命中就派发 `draggingEntered`
/// 等消息；而普通鼠标事件仍然走 `hitTest`。
///
/// 所以这里把 `hitTest` 一律返回 `nil`：
///
/// * 指针事件（点击、滚动、悬停）穿透到下面的 FlutterView，主界面完全照旧；
/// * 拖拽事件照样送进来，因为找的不是 hitTest 的结果。
///
/// 这两件事**必须同时成立**。如果为了接拖拽而让这一层参与 hitTest，
/// 主界面就会变成一块点不动的画——上一版没做拖拽，正是担心这个。
final class WispDropView: NSView {

  /// 松手时回调绝对路径（已去重、保序）。
  var onDrop: (([String]) -> Void)?

  /// 拖拽进入时取一次路径并缓存。
  ///
  /// `draggingUpdated` 在鼠标移动时高频触发，每次都去 pasteboard 上
  /// 反序列化 N 个 URL，拖几百个文件时会明显发涩。进入时取一次，
  /// 移动时只读缓存；松手时再取一次，以"松手那一刻"的真实内容为准
  /// （拖拽期间源文件可能被删掉或改名）。
  private var stagedPaths: [String] = []
  private var active = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    alphaValue = 0
    autoresizingMask = [.width, .height]
    // 只认文件 URL。文本/图片的裸数据落进来没有可发送的本地文件，
    // 与其接住再报错，不如从 Enter 那一刻就不给"可放置"的手势。
    registerForDraggedTypes([.fileURL])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("WispDropView 只从代码创建")
  }

  // MARK: - 指针事件穿透

  /// 见类型注释：只有返回 nil，主界面才点得动。
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  // MARK: - 拖拽

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let paths = Self.filePaths(from: sender.draggingPasteboard)
    guard !paths.isEmpty else {
      stagedPaths = []
      setActive(false)
      return []
    }
    stagedPaths = paths
    setActive(true)
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    return stagedPaths.isEmpty ? [] : .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    stagedPaths = []
    setActive(false)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return !stagedPaths.isEmpty
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = Self.filePaths(from: sender.draggingPasteboard)
    stagedPaths = []
    setActive(false)
    guard !paths.isEmpty else { return false }
    // 文件夹的递归展开交给 Dart：它和「选择文件夹」共用一套逻辑，
    // 原生层只负责把路径交出去（与 Windows 的 WM_DROPFILES 分工一致）。
    onDrop?(paths)
    return true
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    stagedPaths = []
    setActive(false)
  }

  /// 从 pasteboard 取文件 URL。
  ///
  /// `urlReadingFileURLsOnly` 会挡掉 http/文本之类的 URL 项——拖一个链接
  /// 进来不该被当成文件；它同时也保证读出来的一定是 `file://`。
  /// 去重保序：Finder 多选时偶尔会给出重复项，重复发送没有意义。
  private static func filePaths(from pasteboard: NSPasteboard) -> [String] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
    ]
    guard let urls = pasteboard.readObjects(
      forClasses: [NSURL.self], options: options) as? [URL]
    else { return [] }

    var seen = Set<String>()
    var paths: [String] = []
    paths.reserveCapacity(urls.count)
    for url in urls where url.isFileURL {
      let path = url.path
      if path.isEmpty || seen.contains(path) { continue }
      seen.insert(path)
      paths.append(path)
    }
    return paths
  }

  // MARK: - 视觉反馈

  /// 淡入淡出只动 alpha，不动 frame。
  ///
  /// 位置动画一旦丢帧，提示层可能停在屏幕外——这正是 Windows 上
  /// "通知要第二次才出现"的成因，不在这里重犯。
  private func setActive(_ on: Bool) {
    if active == on { return }
    active = on
    if on { needsDisplay = true }
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = on ? 0.12 : 0.16
      animator().alphaValue = on ? 1 : 0
    }, completionHandler: { [weak self] in
      // 初始 alpha 为 0 时系统可能整帧跳过绘制；淡入结束后补一次，
      // 保证提示一定画得出来（否则拖拽能成功，但屏幕上什么都没有）。
      guard let self = self, self.active else { return }
      self.needsDisplay = true
    })
  }

  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    // 淡出期间 active 已经是 false，但 layer 里还留着上一帧内容，
    // 靠 alpha 收尾即可；此时重绘反而会把内容画成"0 项"。
    guard active || alphaValue > 0.01 else { return }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let bounds = self.bounds
    // 窗口被压到极小时画虚线框只会糊成一团。
    guard bounds.width > 160, bounds.height > 140 else { return }

    let dark = WispInk.isDark(effectiveAppearance)
    let plate = bounds.insetBy(dx: 10, dy: 10)
    let radius: CGFloat = 18
    let platePath = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // 一整块淡品牌色：告诉用户"这一整面都能放"，但不糊住下面的界面。
    WispInk.brand.withAlphaComponent(dark ? 0.16 : 0.07).setFill()
    platePath.fill()

    // 虚线是系统里"可以放这里"的通用语言，只是染成品牌色。
    ctx.saveGState()
    ctx.setLineDash(phase: 0, lengths: [9, 7])
    WispInk.brand.withAlphaComponent(dark ? 0.9 : 0.78).setStroke()
    platePath.lineWidth = 2
    platePath.stroke()
    ctx.restoreGState()

    drawBadge(in: plate)
  }

  private func drawBadge(in plate: NSRect) {
    let count = stagedPaths.count
    let title = "松手即可发送"
    let subtitle: String
    if count == 1 {
      subtitle = "1 项内容"
    } else if count > 1 {
      subtitle = "\(count) 项内容"
    } else {
      subtitle = "文件夹会自动展开"
    }

    let titleFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
    let subFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    let white = NSColor.white
    let titleAttrs: [NSAttributedString.Key: Any] = [
      .font: titleFont,
      .foregroundColor: white,
    ]
    let subAttrs: [NSAttributedString.Key: Any] = [
      .font: subFont,
      .foregroundColor: white.withAlphaComponent(0.82),
    ]

    let titleSize = (title as NSString).size(withAttributes: titleAttrs)
    let subSize = (subtitle as NSString).size(withAttributes: subAttrs)
    let padX: CGFloat = 24
    let padY: CGFloat = 13
    let gap: CGFloat = 2

    let badgeWidth = max(titleSize.width, subSize.width) + padX * 2
    let badgeHeight = titleSize.height + gap + subSize.height + padY * 2
    let badge = NSRect(
      x: plate.midX - badgeWidth / 2,
      y: plate.midY - badgeHeight / 2,
      width: badgeWidth,
      height: badgeHeight)

    WispInk.brand.setFill()
    NSBezierPath(roundedRect: badge, xRadius: badgeHeight / 2,
                 yRadius: badgeHeight / 2).fill()

    // 非 flipped 坐标系：原点在左下，两行从胶囊上沿往下排。
    let titleRect = NSRect(
      x: badge.minX + padX,
      y: badge.maxY - padY - titleSize.height,
      width: badge.width - padX * 2,
      height: titleSize.height)
    (title as NSString).draw(in: titleRect, withAttributes: titleAttrs)

    let subRect = NSRect(
      x: badge.minX + padX,
      y: titleRect.minY - gap - subSize.height,
      width: badge.width - padX * 2,
      height: subSize.height)
    (subtitle as NSString).draw(in: subRect, withAttributes: subAttrs)
  }
}
