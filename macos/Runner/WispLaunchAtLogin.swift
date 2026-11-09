import Cocoa
import Foundation
import ServiceManagement

/// 登录时自动运行 Wisp。
///
/// macOS 有两代互不兼容的 API，这里两条都留着：
///
/// * **macOS 13+**：`SMAppService.mainApp`，会出现在「系统设置 → 通用 →
///   登录项与扩展」，用户能在系统里看见、也能关掉——这是正确做法。
/// * **macOS 12**：`~/Library/LaunchAgents` 里的 `RunAtLoad` plist。
///
/// 为什么不全用 LaunchAgent：13+ 上用户从系统设置里禁用登录项时，plist
/// 文件还在，我们查文件就会把开关显示成"已开启"——一个骗人的开关。
///
/// 反过来为什么仍要保留 LaunchAgent：Wisp 的发布产物是 ad-hoc 签名的
/// （未经 Apple 公证/开发者签名），`SMAppService.register()` 有可能直接
/// 抛异常。这时退回 plist 至少让功能可用，而不是给一个永远打不开的开关。
///
/// 两条路径的开关状态都**回查系统**，绝不把"调用没抛异常"当成成功。
enum WispLaunchAtLogin {
  private static let agentLabel = "app.wisp.wisp.launchAtLogin"

  // MARK: - 状态

  static func status() -> [String: Any] {
    var enabled = agentExists
    if #available(macOS 13.0, *) {
      enabled = enabled || serviceEnabled
    }
    // supported 恒为 true：macOS 12 有 plist 回退，不存在"做不了"的系统版本。
    return ["supported": true, "enabled": enabled]
  }

  /// 返回 false 表示没生效。调用方（设置页）会回滚开关并给出提示。
  static func set(_ enabled: Bool) -> Bool {
    if enabled { return enable() }

    // 关闭是幂等的，两条路径都清一遍：从 macOS 12 升级上来的机器可能
    // 还留着旧的 LaunchAgent，不清掉就会出现"开机启动两次"。
    if #available(macOS 13.0, *) {
      try? SMAppService.mainApp.unregister()
    }
    if agentExists { _ = removeAgent() }
    return !(status()["enabled"] as? Bool ?? false)
  }

  private static func enable() -> Bool {
    if #available(macOS 13.0, *) {
      if serviceEnabled { return true }
      do {
        try SMAppService.mainApp.register()
      } catch {
        // 签名/打包不满足 SMAppService 的要求时，退回 plist。
        return writeAgent() && agentExists
      }
      // register 不抛异常也可能只是"等用户在系统设置里批准"
      // （status == .requiresApproval）。此时不能写 plist，否则用户批准
      // 之后会有两份自启；如实返回 false，让界面提示去系统里确认。
      return serviceEnabled
    }
    return writeAgent() && agentExists
  }

  // MARK: - SMAppService（macOS 13+）

  @available(macOS 13.0, *)
  private static var serviceEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  // MARK: - LaunchAgent（macOS 12 及 SMAppService 不可用时）

  private static var agentURL: URL? {
    FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask)
      .first?
      .appendingPathComponent("LaunchAgents", isDirectory: true)
      .appendingPathComponent("\(agentLabel).plist")
  }

  private static var agentExists: Bool {
    guard let url = agentURL else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  /// 只写 plist，不做 `launchctl bootstrap`：这是"下次登录时启动"的语义，
  /// 本次会话里立刻加载反而会弹出第二个窗口。
  private static func writeAgent() -> Bool {
    guard let url = agentURL,
          let executable = Bundle.main.executablePath
    else { return false }
    let plist: [String: Any] = [
      "Label": agentLabel,
      "ProgramArguments": [executable],
      "RunAtLoad": true,
      "KeepAlive": false,
    ]
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private static func removeAgent() -> Bool {
    guard let url = agentURL else { return false }
    if !FileManager.default.fileExists(atPath: url.path) { return true }
    do {
      try FileManager.default.removeItem(at: url)
      return true
    } catch {
      return false
    }
  }
}
