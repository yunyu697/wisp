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
  // 形态进度：0=只剩把手，1=完整球体。球和把手都由它推导（见 RenderBall），
  // 所以两段动画天然接得上，不会"先淡出再淡入"地各演一遍。
  float ball_t_ = 0.0f;
  // 把手上悬停时的放大反馈（0..1）：光标一到就给出回应，不用等展开延时。
  float ball_peek_ = 0.0f;
  int ball_anim_kind_ = 0;       // 0 none 1 expand 2 collapse 3 alert 4 peek-in 5 peek-out
  float ball_anim_from_ = 0.0f;  // 动画起点（ball_t_ 或 ball_peek_）
  ULONGLONG ball_anim_start_ = 0;
  int ball_anim_duration_ = 0;
  UINT_PTR ball_anim_timer_ = 0;
  // 吸附滑行：松手后先滑到边缘，滑到位再缩回把手（原来是瞬移 + 干等 700ms）。
  UINT_PTR ball_snap_timer_ = 0;
  POINT ball_snap_from_{};
  POINT ball_snap_to_{};
  ULONGLONG ball_snap_start_ = 0;
  int ball_snap_duration_ = 0;
  UINT_PTR ball_hover_timer_ = 0;
  UINT_PTR ball_collapse_timer_ = 0;
  UINT_PTR ball_leave_timer_ = 0;
  bool ball_hover_tracked_ = false;
  POINT ball_free_pos_{};        // 未吸附时的自由位置
  // Dart 回传的上次球位置（用于重新启用时恢复；x<0 表示无记录）。
  POINT ball_saved_pos_{-1, -1};
  bool ball_saved_snapped_ = false;
  int ball_saved_edge_ = -1;

  // 空闲变暗：失去"焦点"（光标离开）1s 后，用 1s 淡到 25%；
  // 光标回来时用 120ms 迅速回到不透明（不能闪，所以只走单向过渡）。
  float ball_dim_ = 1.0f;        // 当前不透明度系数 0.25..1
  float ball_dim_from_ = 1.0f;
  float ball_dim_to_ = 1.0f;
  ULONGLONG ball_dim_start_ = 0;
  int ball_dim_duration_ = 0;
  UINT_PTR ball_dim_timer_ = 0;
  UINT_PTR ball_idle_timer_ = 0;
  // 置顶守护：轮询前台窗口，全屏应用在用时先把球藏起来，退出全屏再回来。
  UINT_PTR ball_top_timer_ = 0;
  bool ball_hidden_by_fullscreen_ = false;
  HWND ball_last_foreground_ = nullptr;
  // 最近一次绘制用的全局参数，变暗重绘时按原样复用。
  BYTE ball_alpha_ = 255;
  float ball_scale_ = 1.0f;

  // --- bubble window (next to the ball) ---
  HWND bubble_window_ = nullptr;
  std::wstring bubble_title_;
  std::wstring bubble_body_;
  std::wstring bubble_progress_;  // 如 "45%"，空表示不显示进度条
  int bubble_mode_ = 0;           // 0=ask 1=progress 2=done
  UINT_PTR bubble_timeout_timer_ = 0;
  POINT bubble_anchor_{0, 0};     // 气泡左上角的固定落点（屏幕坐标）
  // 气泡这一轮流程是否活着（比 IsWindowVisible 准，窗口刚隐藏时会误判）。
  bool bubble_active_ = false;
  // 最近一次绘制是否真的成功（UpdateLayeredWindow 没报错）。
  bool bubble_drawn_ = false;
  // 气泡进出场动画：1=淡入（从球的方向滑入）2=淡出（滑回球的方向）。
  UINT_PTR bubble_anim_timer_ = 0;
  int bubble_anim_kind_ = 0;
  ULONGLONG bubble_anim_start_ = 0;
  int bubble_anim_duration_ = 0;
  int bubble_slide_dx_ = 0;  // 入场起点的偏移（物理像素），落点为 0
  int bubble_slide_dy_ = 0;

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

  // --- floating ball ---
  void SetFloatingBall(bool enabled, int hover_delay_ms);
  void ShowBallAlert();
  void ExpandBall(bool animate);
  void CollapseBall();
  void SnapBallToEdge();  void CreateBallWindow();
  void DestroyBallWindow();
  /// t: 0=把手 1=球体（中间值即两者的过渡形态）；alpha 全局不透明度；
  /// scale 呼吸缩放（提示动画用）。
  void RenderBall(float t, BYTE alpha, float scale);
  void StartBallAnim(int kind);
  void StepBallAnim();
  void StepBallSnap();
  void StopBallAnims();
  // 光标在球上（含拖动、提示中）：取消空闲计时并立刻回到不透明。
  void NoteBallActivity();
  // 光标离开：安排 1s 后的空闲变暗。
  void ScheduleBallIdle();
  // dim=true 慢慢变暗，false 迅速恢复。
  void StartBallDim(bool dim);
  void StepBallDim();
  // 全屏应用在用就把球藏起来，否则重申置顶。
  void UpdateBallTopmost();
  bool FullscreenAppForeground();
  RECT BallWorkArea() const;
  // 悬浮球当前可见内容（展开=球体，吸附=把手）的屏幕矩形。
  RECT BallContentRect() const;

  // --- bubble ---
  void ShowBubble(const std::wstring& title, const std::wstring& body, int mode,
                  const std::wstring& progress);
  void UpdateBubble(const std::wstring& body, int mode, const std::wstring& progress);
  /// 收起气泡。
  ///
  /// `animate = false` 是"立刻消失"，用在**恢复主窗口之前**：用户已经回到主窗口，
  /// 没必要再让一个置顶的分层窗口在它上面演退场动画。
  void HideBubble(bool animate = true);
  void CreateBubbleWindow();
  void DestroyBubbleWindow();
  void RenderBubble();
  /// fade: 整体不透明度 0..1；dx/dy: 相对落点的像素偏移（入场滑入用）。
  void RenderBubbleAt(float fade, int dx, int dy);
  /// 按当前动画帧重画（没有动画时就是完整不透明度）。
  void RefreshBubble();
  void StartBubbleAnim(int kind);
  void StepBubbleAnim();
  void HandleBubbleClick(POINT pt);


  // 悬浮球/气泡/通知的独立窗口过程需要读写这些私有状态，声明为友元。
  friend LRESULT CALLBACK BallWndProc(HWND, UINT, WPARAM, LPARAM);
  friend LRESULT CALLBACK BubbleWndProc(HWND, UINT, WPARAM, LPARAM);
  friend LRESULT CALLBACK ToastWndProc(HWND, UINT, WPARAM, LPARAM);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
