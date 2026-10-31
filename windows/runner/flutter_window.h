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
// even when the window is hidden, a custom-drawn notification card, a
// draggable floating ball (with an edge handle for instant recall) and its
// bubble for handling incoming requests without opening the main window,
// a minimum window size, and a small method channel the Dart side uses to
// drive all of it.
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

  // --- floating ball ---
  // The ball window is always kBallWindow logical px. Expanded state draws
  // the ball image centred; handle state draws only a slim pill hugging the
  // snapped screen edge (rest of the window is fully transparent, and
  // transparent pixels are click-through, so only the handle is hot).
  HWND ball_window_ = nullptr;
  bool ball_expanded_ = false;   // true=完整球体 false=吸附后的把手
  bool ball_snapped_ = false;    // 是否吸附在屏幕边缘
  int ball_edge_ = 1;            // 0 left 1 right 2 top 3 bottom
  int ball_hover_delay_ms_ = 300;
  int ball_anim_kind_ = 0;       // 0 none 1 expand 2 collapse 3 alert
  int ball_anim_phase_ = 0;
  UINT_PTR ball_anim_timer_ = 0;
  UINT_PTR ball_hover_timer_ = 0;
  UINT_PTR ball_collapse_timer_ = 0;
  UINT_PTR ball_leave_timer_ = 0;
  bool ball_hover_tracked_ = false;
  POINT ball_free_pos_{};        // 未吸附时的自由位置
  // Dart 回传的上次球位置（用于重新启用时恢复；x<0 表示无记录）。
  POINT ball_saved_pos_{-1, -1};
  bool ball_saved_snapped_ = false;
  int ball_saved_edge_ = -1;

  // --- bubble window (next to the ball) ---
  HWND bubble_window_ = nullptr;
  std::wstring bubble_title_;
  std::wstring bubble_body_;
  std::wstring bubble_progress_;  // 如 "45%"，空表示不显示进度条
  int bubble_mode_ = 0;           // 0=ask 1=progress 2=done
  UINT_PTR bubble_timeout_timer_ = 0;
  POINT bubble_anchor_{0, 0};     // 气泡左上角的固定落点（屏幕坐标）

  // --- custom toast notification (bottom-right card) ---
  HWND toast_window_ = nullptr;
  std::wstring toast_title_;
  std::wstring toast_body_;
  std::wstring toast_progress_;
  int toast_mode_ = 0;  // 0=ask 1=progress 2=done
  UINT_PTR toast_timeout_timer_ = 0;
  UINT_PTR toast_anim_timer_ = 0;
  int toast_anim_phase_ = 0;
  POINT toast_anchor_{0, 0};  // 卡片落点；动画帧只相对它做位移，绝不累加
  UINT_PTR restore_redraw_timer_ = 0;

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
  void RenderToast(float slide_t);   // slide_t: 0=画外 1=就位
  void HandleToastClick(POINT pt);

  // --- 打开外部链接 ---
  // 用 ShellExecuteW 把 http(s) 交给系统默认浏览器。
  // 不能用 `explorer.exe <url>`：从 Flutter 子进程里调它拉不起浏览器，
  // 用户点了「下载最新版」没反应。返回 ShellExecute 的错误码（>32 表示成功）。
  int OpenUrl(const std::wstring& url);

  // --- floating ball ---
  void SetFloatingBall(bool enabled, int hover_delay_ms);
  void ShowBallAlert();
  void ExpandBall(bool animate);
  void CollapseBall();
  void SnapBallToEdge();  void CreateBallWindow();
  void DestroyBallWindow();
  void RenderBall(float expand_t, BYTE alpha, float scale);
  void StartBallAnim(int kind);
  void StopBallAnims();
  RECT BallWorkArea() const;
  // 悬浮球当前可见内容（展开=球体，吸附=把手）的屏幕矩形。
  RECT BallContentRect() const;

  // --- bubble ---
  void ShowBubble(const std::wstring& title, const std::wstring& body, int mode,
                  const std::wstring& progress);
  void UpdateBubble(const std::wstring& body, int mode, const std::wstring& progress);
  void HideBubble();
  void CreateBubbleWindow();
  void DestroyBubbleWindow();
  void RenderBubble();
  void HandleBubbleClick(POINT pt);


  // 悬浮球/气泡/通知的独立窗口过程需要读写这些私有状态，声明为友元。
  friend LRESULT CALLBACK BallWndProc(HWND, UINT, WPARAM, LPARAM);
  friend LRESULT CALLBACK BubbleWndProc(HWND, UINT, WPARAM, LPARAM);
  friend LRESULT CALLBACK ToastWndProc(HWND, UINT, WPARAM, LPARAM);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
