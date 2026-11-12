#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <string>

#include "win32_window.h"

// Hosts a Flutter view, and adds the desktop niceties Wisp needs:
// a system-tray icon (with flashing) so incoming transfers can reach the user
// even when the window is hidden, a custom-drawn notification card (the
// floating ball and its bubble have been retired), a minimum window size,
// and a small method channel the Dart side uses to drive all of it.
class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Channel used by the Dart side to control window behaviour.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // Tray icon state.
  NOTIFYICONDATA tray_data_{};
  bool tray_visible_ = false;

  // Tray flashing (incoming request attention).
  bool flashing_ = false;
  int flash_frame_ = 0;
  UINT_PTR flash_timer_ = 0;

  // Whether the close button hides to the tray instead of quitting.
  bool minimize_to_tray_ = true;

  // Whether the user already asked to close the window. Used to avoid the
  // first-frame callback popping the window back up after it was hidden.
  bool close_requested_ = false;

  // --- 启动可见性（静默启动） ---
  //
  // 首帧画好之后**不**立刻显示，先等 Dart 读完设置告诉我们这一次要不要露面。
  // 原因是"静默启动"是用户设置，只有 Dart 侧知道；原生层先显示再隐藏会闪一下。
  // Dart 迟迟不回（设置读失败、通道异常）就用兜底计时器照常显示，绝不把窗口
  // 永久藏起来——那等于应用启动后什么也没发生。
  bool first_frame_ready_ = false;
  bool startup_decided_ = false;
  bool startup_visible_ = true;
  bool shown_once_ = false;
  UINT_PTR startup_timer_ = 0;
  // force=true 时不等首帧（兜底路径：首帧迟迟不来也得把窗口亮出来）。
  void MaybeShowOnStartup(bool force = false);

  // --- 窗口可见性（不可见时停掉 Dart 侧的循环动画） ---
  //
  // 收进托盘 / 最小化之后，Flutter 引擎仍然按 60fps 出帧：主界面那圈
  // "正在寻找附近的设备"雷达是无限动画，没人看也照画，空转吃掉 25~50% CPU。
  // 把可见性推给 Dart，由 TickerMode 统一静音所有 ticker——单个页面自己
  // 判断窗口状态是治不住的，以后新加动画又会漏。
  //
  // visible_hint：WM_SHOWWINDOW 是"即将显示/隐藏"时发出的，那时
  // IsWindowVisible() 还没落地（隐藏时仍返回 TRUE），必须按 wParam 直接表态，
  // 不能现场查。传 -1 表示没有提示、现场查。
  void NotifyWindowVisibility(bool force = false, int visible_hint = -1);
  // 上一次推给 Dart 的值，用来去重：WM_SIZE / WM_SHOWWINDOW 会连着来好几条，
  // 不去重就是每拖一下窗口都过一遍通道。
  bool last_window_visible_ = true;

  // --- 主窗口尺寸/位置记忆 ---
  // 存在注册表 HKCU\Software\Wisp\WindowPlacement（一段二进制记录），
  // 没有记录时按竖屏比例居中打开。
  void ApplyWindowPlacement();
  void SaveWindowPlacement();
  // 最近一次"正常态"（非最大化、非最小化）的窗口矩形，单位物理像素。
  RECT last_normal_rect_{0, 0, 0, 0};
  bool placement_maximized_ = false;

  // --- custom toast notification (bottom-right card) ---
  HWND toast_window_ = nullptr;
  std::wstring toast_title_;
  std::wstring toast_body_;
  std::wstring toast_progress_;
  int toast_mode_ = 0;  // 0=ask 1=progress 2=done
  UINT_PTR toast_timeout_timer_ = 0;
  UINT_PTR toast_anim_timer_ = 0;
  ULONGLONG toast_anim_start_ = 0;
  POINT toast_anchor_{0, 0};  // 卡片落点（位置永远固定，动画只调透明度）
  bool toast_active_ = false;
  bool toast_drawn_ = false;
  UINT_PTR restore_redraw_timer_ = 0;
  int restore_redraw_step_ = 0;

  // --- tray ---
  void CreateTrayIcon();
  void DestroyTrayIcon();
  void ShowTrayMenu();
  void RestoreWindow();

  // Sends an event back to the Dart side.
  void InvokeDart(const std::string& method, flutter::EncodableMap args);

  // --- tray attention ---
  void SetTrayFlashing(bool flashing);

  // --- custom toast card (ask / progress / done) ---
  void ShowToast(const std::wstring& title, const std::wstring& body, int mode,
                 const std::wstring& progress);
  void UpdateToast(const std::wstring& body, int mode, const std::wstring& progress);
  void HideToast();
  void CreateToastWindow();
  void DestroyToastWindow();
  void RenderToast(float fade);   // fade: 0..1 整体不透明度，位置固定
  void HandleToastClick(POINT pt);

  // --- 主窗口重绘 ---
  // 收起置顶浮层 / 从隐藏态恢复后必须强制重绘，否则主窗口会留黑块。
  void ForceMainWindowRepaint();
  void ScheduleRestoreRedraws();
  void RunRestoreRedrawStep();

  // --- 打开外部链接 ---
  // 用 ShellExecuteW 把 http(s) 交给系统默认浏览器。
  // 不能用 `explorer.exe <url>`：从 Flutter 子进程里调它拉不起浏览器，
  // 用户点了「下载最新版」没反应。返回 ShellExecute 的错误码（>32 表示成功）。
  int OpenUrl(const std::wstring& url);

  // --- 启动安装程序（自动更新） ---
  // 动词用 "runas" 才会弹 UAC（安装器要管理员权限）；只放行 .exe 路径。
  bool RunInstaller(const std::wstring& path, const std::wstring& args);

  // 通知卡落点：按主窗口所在显示器的工作区定位桌面通知卡。
  // 不加 const：要调 Win32Window::GetHandle()，它是非 const 方法。
  RECT ToastWorkArea();

  // 通知卡的独立窗口过程需要读写这些私有状态，声明为友元。
  friend LRESULT CALLBACK ToastWndProc(HWND, UINT, WPARAM, LPARAM);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
