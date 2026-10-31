import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 关窗驻留菜单栏：窗口关了应用继续跑（接收服务不能停）。
    // 真正退出走 Cmd+Q / 菜单栏「退出」，terminate 不受这里影响。
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
