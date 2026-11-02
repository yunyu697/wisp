#include "flutter_window.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cwctype>
#include <gdiplus.h>
#include <optional>
#include <shellapi.h>
#include <string>
#include <vector>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"
#include "keepalive_service.h"
#include "resource.h"

// GDI+ 的坐标 API 全部是 float(REAL)，和整数的 DPI 换算值混用是有意为之，
// 这几类数值转换警告对本文件而言都是无损的，整体豁免（警告被当作错误）。
#pragma warning(disable : 4244 4310 4838)

namespace {

// Tray icon callback message.
constexpr UINT kTrayMessage = WM_APP + 1;

// Tray menu command ids.
constexpr UINT kTrayCommandShow = 1001;
constexpr UINT kTrayCommandQuit = 1002;

// Minimum window size in logical pixels. Below this the layout starts to
// break, so the window refuses to shrink any further.
//
// 高度 690 不是随手取的：最窄宽度下首页（页头 + 身份卡 + 雷达 + 说明 +
// 「输入 IP 直接连接」按钮）内容高 617，加上底部导航栏 71，正好 688。
// 也就是说 690 是「所有元素一屏放得下、不需要滚动」的下限，
// 再矮就会把按钮挤出首屏。改动这两处布局时记得同步回来。
constexpr LONG kMinWindowWidth = 420;
constexpr LONG kMinWindowHeight = 690;

// 首次启动（没有记忆位置）时的窗口尺寸：竖屏比例，居中打开。
//
// 竖屏是这套界面的设计意图（底部导航 + 单栏，和手机一致），横屏那套侧边栏
// 是"窗口被拉宽之后"的适配。所以第一次见面给一个竖屏窗口，而不是随手 1280×720。
// 高度按工作区夹过（见 ApplyWindowPlacement），小屏笔记本上也放得下。
constexpr int kDefaultWindowWidth = 440;
constexpr int kDefaultWindowHeight = 820;

// 首帧画好之后等 Dart 表态的上限。超时就当"要显示"——把窗口永久藏起来
// 比多弹一次窗口糟糕得多。
constexpr int kStartupFallbackMs = 1500;

// Window class names.
constexpr wchar_t kBallClass[] = L"WISP_FLOAT_BALL";
constexpr wchar_t kBubbleClass[] = L"WISP_BUBBLE";
constexpr wchar_t kToastClass[] = L"WISP_TOAST";

// --- 悬浮球几何（逻辑像素） ---
// 窗口边长；ball.png 里球体占 78%，扣除吸附留边后球的可见直径约 55。
constexpr int kBallWindow = 84;
constexpr int kSnapMargin = 28;    // 拖到距边多近算吸附
constexpr int kHandleSize = 11;    // 把手粗细
constexpr int kHandleLength = 46;  // 把手长度
// 吸附后球心距屏幕边缘的距离（把手露出量）。
constexpr int kHandleOutset = 6;

// --- 通知卡片几何（内容区，另加阴影边距） ---
//
// 通知卡片与悬浮球气泡**共用同一套几何与字体**（规则 7：三种通知字体、
// 内容、布局必须一致）。以前气泡 300×172、卡片 340×118 各写一套，
// 结果字号一样但行宽不同，观感差得明显。
constexpr int kCardWidth = 340;
constexpr int kCardHeight = 132;
constexpr int kCardMargin = 16;  // 阴影边距

// 卡片模式（与 Dart 侧 DesktopService.bubbleAsk/Progress/Done/Canceled 对齐）：
// 0=询问 1=进度 2=完成 3=取消/中断提示（无按钮，看完自动收）。
// 询问给 30s：用户要决定收不收，8s 太仓促，是"通知闪一下就没了"的另一半来源。
// 取消提示只给 3s：明确告知结局即可，停留太久反而像没关掉。
constexpr int kCardModeAsk = 0;
constexpr int kCardModeProgress = 1;
constexpr int kCardModeDone = 2;
constexpr int kCardModeCanceled = 3;

// 通知卡入场动画的起始不透明度。
//
// 不是 0：即使动画帧一次都没跑到（平台线程忙、计时器被清掉），卡片也已经在
// 正确的位置上、只是淡一点。取 0 就会出现"卡片在屏幕外、用户看不见"的坑。
constexpr float kToastFadeStart = 0.6f;

UINT_PTR ToastLifetimeMs(int mode) {
  switch (mode) {
    case kCardModeAsk:
      return 30000;
    case kCardModeCanceled:
      return 3000;
    default:
      return 8000;  // 进度 / 完成
  }
}

// --- 动画时长（毫秒） ---
//
// 全部按"经过时间 → 进度"求值，而不是数帧：SetTimer 的实际间隔是 15.6ms
// 的倍数，数帧会让同一段动画在不同机器上时长不一样，慢机器上还会掉帧。
constexpr int kBallExpandMs = 360;
constexpr int kBallCollapseMs = 300;
constexpr int kBallAlertMs = 1100;
constexpr int kBallPeekMs = 140;
constexpr int kBubbleInMs = 200;
constexpr int kBubbleOutMs = 150;
constexpr int kToastFadeMs = 200;

// 空闲变暗：光标离开 1s 后开始，用 1s 淡到 25%；
// 光标回来时只用 120ms 就回到不透明——"迅速"，但仍是渐变，不会闪。
constexpr int kBallIdleDelayMs = 1000;
constexpr int kBallDimMs = 1000;
constexpr int kBallUndimMs = 120;
constexpr float kBallDimAlpha = 0.25f;
// 置顶守护轮询间隔。600ms 足够跟上全屏切换，又不至于太费。
constexpr int kBallTopPollMs = 600;

// 悬浮球动画种类。
constexpr int kBallAnimExpand = 1;
constexpr int kBallAnimCollapse = 2;
constexpr int kBallAnimAlert = 3;
constexpr int kBallAnimPeekIn = 4;
constexpr int kBallAnimPeekOut = 5;

// --- 缓动 ---
float Clamp01(float x) { return x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x); }

// 两端都平滑（0 处一阶导为 0）：用于"把手 ⇄ 球"这种来回切换的量，
// 收尾时速度归零，不会有"啪"地一下停住的硬切感。
float SmoothStep01(float x) {
  x = Clamp01(x);
  return x * x * (3.0f - 2.0f * x);
}

float EaseOutCubic(float x) {
  x = Clamp01(x);
  const float y = 1.0f - x;
  return 1.0f - y * y * y;
}

float EaseInOutCubic(float x) {
  x = Clamp01(x);
  if (x < 0.5f) return 4.0f * x * x * x;
  const float y = -2.0f * x + 2.0f;
  return 1.0f - (y * y * y) / 2.0f;
}

// 形态变化用的"慢起 + 末尾回弹"曲线：0→1 的过程中先匀速长满，最后弹一下。
//
// 试过两种更"教科书"的做法，都不合用：
//  * S 曲线：只是平滑到位，没有回弹，像橡皮筋被拉住不放；
//  * 阻尼振荡解析式 1-e^(-dt)cos(wt)：起手斜率就等于阻尼系数，t=0.2 时已经
//    走到 95%，看着还是"啪"地一下长满（实测抓帧只录到 4 帧过渡）。
//
// 这里显式分成两段：前 68% 用 SmoothStep 慢慢长满（起手速度为 0），
// 后 32% 叠一个正弦回弹，峰值过冲约 7%，收尾回到 1。
float Spring01(float x) {
  x = Clamp01(x);
  constexpr float kRise = 0.72f;
  if (x <= kRise) return SmoothStep01(x / kRise);
  const float k = (x - kRise) / (1.0f - kRise);
  return 1.0f + 0.07f * std::sin(k * 3.14159265f);
}

// Timer ids。主窗口 2/11，球窗口 3/6/7/8/12/14/15/16，气泡 5/13，通知 9/10。
constexpr UINT_PTR kFlashTimerId = 2;
constexpr UINT_PTR kBallAnimTimerId = 3;
constexpr UINT_PTR kBubbleTimeoutTimerId = 5;
constexpr UINT_PTR kBallHoverTimerId = 6;
constexpr UINT_PTR kBallCollapseTimerId = 7;
constexpr UINT_PTR kBallLeaveTimerId = 8;
constexpr UINT_PTR kToastAnimTimerId = 9;
constexpr UINT_PTR kToastTimeoutTimerId = 10;
constexpr UINT_PTR kRestoreRedrawTimerId = 11;
constexpr UINT_PTR kBallSnapTimerId = 12;
constexpr UINT_PTR kBubbleAnimTimerId = 13;
constexpr UINT_PTR kBallDimTimerId = 14;
constexpr UINT_PTR kBallIdleTimerId = 15;
constexpr UINT_PTR kBallTopTimerId = 16;
constexpr UINT_PTR kStartupTimerId = 17;

// 主窗口恢复后的连续重绘次数（间隔 60/120/240/480/960ms）。
constexpr int kRestoreRedrawSteps = 6;

// Wisp 品牌色：与 `lib/core/design/app_colors.dart` 的 WispColors 逐值对齐
// （teal / coral / 暖中性）。改色必须两边同时改，否则通知卡和界面会不同色。
constexpr COLORREF kBrand = RGB(14, 124, 134);   // WispColors.teal
constexpr COLORREF kAccent = RGB(255, 122, 89);  // WispColors.coral：图标上的那颗点
constexpr COLORREF kText = RGB(23, 25, 26);      // lightText
constexpr COLORREF kSubText = RGB(107, 113, 112);  // lightTextSecondary
constexpr COLORREF kCardBg = RGB(255, 255, 255);   // lightSurface
constexpr COLORREF kChipBg = RGB(237, 235, 228);   // lightSurfaceAlt
constexpr COLORREF kLine = RGB(229, 226, 218);     // lightLine

// The single FlutterWindow, used to route ball/bubble/toast messages.
FlutterWindow* g_instance = nullptr;

// 诊断日志（写进 exe 同目录）。
//
// 只在异常路径上写，但渲染每帧失败时也会走到这里——不设上限能把磁盘写满。
// 超过 512 KB 就整份重写，保留最近的现场足够定位问题。
void WispDbgLog(const std::string& message) {
  char path[MAX_PATH];
  GetModuleFileNameA(nullptr, path, MAX_PATH);
  std::string dir(path);
  size_t slash = dir.find_last_of("\\/");
  if (slash != std::string::npos) dir = dir.substr(0, slash + 1);
  dir += "wisp_native_debug.log";

  constexpr unsigned long long kMaxLogBytes = 512ull * 1024ull;
  WIN32_FILE_ATTRIBUTE_DATA attr = {};
  bool truncate = false;
  if (GetFileAttributesExA(dir.c_str(), GetFileExInfoStandard, &attr)) {
    const unsigned long long size =
        (static_cast<unsigned long long>(attr.nFileSizeHigh) << 32) |
        static_cast<unsigned long long>(attr.nFileSizeLow);
    truncate = size > kMaxLogBytes;
  }

  FILE* f = nullptr;
  fopen_s(&f, dir.c_str(), truncate ? "w" : "a");
  if (f != nullptr) {
    fprintf(f, "%s\n", message.c_str());
    fclose(f);
  }
}

// ---------------------------------------------------------------------------
// GDI+ 生命周期与全局贴图
// ---------------------------------------------------------------------------

ULONG_PTR g_gdiplus_token = 0;
// 悬浮球现在全部用 GDI+ 现画（见 RenderBall），不再需要 ball.png 贴图：
// 贴图里烤死的硬边阴影正是"双边框"的来源，而且贴图做不了形状形变。

void EnsureGdiplus() {
  if (g_gdiplus_token != 0) return;
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::Status st = GdiplusStartup(&g_gdiplus_token, &input, nullptr);
  WispDbgLog("GdiplusStartup status=" + std::to_string((int)st) +
             " token=" + std::to_string(g_gdiplus_token));
}

void ShutdownGdiplus() {
  if (g_gdiplus_token != 0) {
    Gdiplus::GdiplusShutdown(g_gdiplus_token);
    g_gdiplus_token = 0;
  }
}

HICON LoadAppIcon() {
  return LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
}

int ScaleFor(HWND hwnd, int value) {
  UINT dpi = GetDpiForWindow(hwnd);
  double scale = dpi > 0 ? dpi / 96.0 : 1.0;
  return static_cast<int>(value * scale);
}

// 字体尺寸用的缩放系数。GDI+ 的 UnitPixel 是**物理像素**，不随窗口 DPI 放大，
// 所以 200% 缩放下字号只有设计值的一半——悬浮球气泡"字体特别小"就是这么来的。
// 所有字号都必须乘这个系数。
float DpiScaleOf(HWND hwnd) {
  UINT dpi = GetDpiForWindow(hwnd);
  return dpi > 0 ? static_cast<float>(dpi) / 96.0f : 1.0f;
}

// 托盘闪烁徽章：正常图标右上角叠一颗品牌色圆点，alpha 呼吸（帧序列）。
// 相比"两个图标硬切"，徽章渐隐渐现平滑得多。
constexpr int kFlashFrames = 8;
HICON g_badge_icons[kFlashFrames] = {};

Gdiplus::GraphicsPath* RoundedRect(const Gdiplus::RectF& r, float radius);

HICON CreateBadgeIcon(int frame) {
  const BYTE alpha = static_cast<BYTE>(
      60 + (255 - 60) * (0.5 + 0.5 * sin(frame / static_cast<double>(kFlashFrames) *
                                          6.28318530718)));
  const int size = GetSystemMetrics(SM_CXICON);
  HDC screen = GetDC(nullptr);
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = size;
  bi.bmiHeader.biHeight = -size;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP color =
      CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  HDC mem = CreateCompatibleDC(screen);
  HGDIOBJ old = SelectObject(mem, color);
  ZeroMemory(bits, static_cast<size_t>(size) * size * 4);
  DrawIconEx(mem, 0, 0, LoadAppIcon(), size, size, 0, nullptr, DI_NORMAL);
  {
    Gdiplus::Graphics g(mem);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    float d = size * 0.44f;
    Gdiplus::RectF badge(size - d - size * 0.03f, size * 0.03f, d, d);
    Gdiplus::GraphicsPath* ring = RoundedRect(badge, d / 2);
    Gdiplus::SolidBrush ring_brush(Gdiplus::Color(235, 255, 255, 255));
    g.FillPath(&ring_brush, ring);
    delete ring;
    float inset = size * 0.055f;
    Gdiplus::RectF inner(badge.X + inset, badge.Y + inset,
                         badge.Width - inset * 2, badge.Height - inset * 2);
    Gdiplus::GraphicsPath* dot = RoundedRect(inner, inner.Width / 2);
    Gdiplus::SolidBrush dot_brush(Gdiplus::Color(
        alpha, GetRValue(kAccent), GetGValue(kAccent), GetBValue(kAccent)));
    g.FillPath(&dot_brush, dot);
    delete dot;
  }
  SelectObject(mem, old);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);

  HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
  HDC mask_dc = CreateCompatibleDC(screen);
  HGDIOBJ om = SelectObject(mask_dc, mask);
  PatBlt(mask_dc, 0, 0, size, size, BLACKNESS);  // 0 = 交给 color 的 alpha
  SelectObject(mask_dc, om);
  DeleteDC(mask_dc);
  ReleaseDC(nullptr, screen);

  ICONINFO info{};
  info.fIcon = TRUE;
  info.hbmMask = mask;
  info.hbmColor = color;
  HICON icon = CreateIconIndirect(&info);
  DeleteObject(color);
  DeleteObject(mask);
  return icon;
}

// ---------------------------------------------------------------------------
// 逐像素 alpha 的分层窗口渲染
// ---------------------------------------------------------------------------

// 一个"画完就 UpdateLayeredWindow"的画布。
// 用法：Begin(hwnd, w, h) → graphics() 上用 GDI+ 画 → Present(hwnd, x, y)。
// 注意：整条绘制链路必须用 GDI+（GDI 会把 alpha 写成 0）。
class LayeredCanvas {
 public:
  ~LayeredCanvas() { Discard(); }

  bool Begin(HWND hwnd, int w, int h) {
    Discard();
    hwnd_ = hwnd;
    w_ = w;
    h_ = h;
    ZeroMemory(&bi_, sizeof(bi_));
    bi_.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi_.bmiHeader.biWidth = w;
    bi_.bmiHeader.biHeight = -h;  // top-down
    bi_.bmiHeader.biPlanes = 1;
    bi_.bmiHeader.biBitCount = 32;
    bi_.bmiHeader.biCompression = BI_RGB;
    screen_ = GetDC(nullptr);
    dc_ = CreateCompatibleDC(screen_);
    bmp_ = CreateDIBSection(screen_, &bi_, DIB_RGB_COLORS, &bits_, nullptr, 0);
    if (bmp_ == nullptr) {
      Discard();
      return false;
    }
    old_ = SelectObject(dc_, bmp_);
    ZeroMemory(bits_, static_cast<size_t>(w) * h * 4);  // 全透明起点
    // 用 PARGB 格式包装同一段内存，Graphics 才会正确写预乘 alpha。
    // （从 HDC 直接创建的 Graphics 把表面当不透明 RGB，alpha 全写 0。）
    // PixelFormat32bppPARGB 是宏（不是 Gdiplus:: 枚举），不能加命名空间限定。
    wrapped_ = new Gdiplus::Bitmap(w, h, w * 4, PixelFormat32bppPARGB,
                                   static_cast<BYTE*>(bits_));
    gfx_.reset(Gdiplus::Graphics::FromImage(wrapped_));
    if (gfx_ == nullptr) {
      Discard();
      return false;
    }
    gfx_->SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    gfx_->SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    gfx_->SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    gfx_->SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
    return true;
  }

  Gdiplus::Graphics* graphics() { return gfx_.get(); }
  int width() const { return w_; }
  int height() const { return h_; }

  // 整体不透明度：把画布上每个像素乘上 factor（0..255）。
  //
  // 画布是预乘 alpha 的，RGB 已经乘过 alpha，所以 RGB 和 alpha 一起按
  // 同一个系数缩放，才不会破坏预乘关系（只缩 alpha 会让 RGB > A，
  // 合成时边缘发亮）。
  void ApplyAlpha(BYTE factor) {
    if (bits_ == nullptr || factor == 255) return;
    BYTE* p = static_cast<BYTE*>(bits_);
    const size_t count = static_cast<size_t>(w_) * h_;
    for (size_t i = 0; i < count; i++) {
      p[i * 4 + 0] = static_cast<BYTE>(p[i * 4 + 0] * factor / 255);
      p[i * 4 + 1] = static_cast<BYTE>(p[i * 4 + 1] * factor / 255);
      p[i * 4 + 2] = static_cast<BYTE>(p[i * 4 + 2] * factor / 255);
      p[i * 4 + 3] = static_cast<BYTE>(p[i * 4 + 3] * factor / 255);
    }
  }

  // 把画布内容提交到窗口，(x, y) 是窗口左上角的屏幕坐标（可为 nullptr 保持）。
  // 返回 false 表示 UpdateLayeredWindow 失败——调用方据此知道"这次没画出来"。
  bool Present(HWND hwnd, const POINT* dst) {
    if (dc_ == nullptr) return false;
    gfx_.reset();
    delete wrapped_;
    wrapped_ = nullptr;
    // 注意顺序：UpdateLayeredWindow 要求位图仍选中在 hdcSrc 里，
    // 恢复 old_ 必须放在 ULW 之后（Discard 里做）。
    POINT src{0, 0};
    SIZE size{w_, h_};
    BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    // ULW 对"尚未显示的窗口"不接受空目标位置，这里总是显式给出当前矩形。
    POINT dst_pt{0, 0};
    if (dst == nullptr) {
      RECT wr;
      GetWindowRect(hwnd, &wr);
      dst_pt = POINT{wr.left, wr.top};
      dst = &dst_pt;
    }
    BOOL ok = UpdateLayeredWindow(hwnd, screen_, const_cast<POINT*>(dst), &size,
                                  dc_, &src, 0, &bf, ULW_ALPHA);
    if (!ok) {
      WispDbgLog("UpdateLayeredWindow failed gle=" +
                 std::to_string(GetLastError()));
    }
    Discard();
    return ok != FALSE;
  }

 private:
  void Discard() {
    if (gfx_) gfx_.reset();
    if (wrapped_ != nullptr) {
      delete wrapped_;
      wrapped_ = nullptr;
    }
    if (old_ != nullptr) {
      SelectObject(dc_, old_);
      old_ = nullptr;
    }
    if (bmp_ != nullptr) {
      DeleteObject(bmp_);
      bmp_ = nullptr;
    }
    if (dc_ != nullptr) {
      DeleteDC(dc_);
      dc_ = nullptr;
    }
    if (screen_ != nullptr) {
      ReleaseDC(nullptr, screen_);
      screen_ = nullptr;
    }
  }

  HWND hwnd_ = nullptr;
  int w_ = 0;
  int h_ = 0;
  HDC screen_ = nullptr;
  HDC dc_ = nullptr;
  HBITMAP bmp_ = nullptr;
  HGDIOBJ old_ = nullptr;
  void* bits_ = nullptr;
  BITMAPINFO bi_{};
  std::unique_ptr<Gdiplus::Graphics> gfx_;
  Gdiplus::Bitmap* wrapped_ = nullptr;
};

Gdiplus::GraphicsPath* RoundedRect(const Gdiplus::RectF& r, float radius) {
  auto* path = new Gdiplus::GraphicsPath();
  float d = radius * 2;
  if (d > r.Width) d = r.Width;
  if (d > r.Height) d = r.Height;
  path->AddArc(r.X, r.Y, d, d, 180, 90);
  path->AddArc(r.X + r.Width - d, r.Y, d, d, 270, 90);
  path->AddArc(r.X + r.Width - d, r.Y + r.Height - d, d, d, 0, 90);
  path->AddArc(r.X, r.Y + r.Height - d, d, d, 90, 90);
  path->CloseFigure();
  return path;
}

void FillRound(Gdiplus::Graphics& g, const Gdiplus::RectF& r, float radius,
               COLORREF color, int alpha = 255) {
  Gdiplus::GraphicsPath* path = RoundedRect(r, radius);
  Gdiplus::SolidBrush brush(Gdiplus::Color(
      static_cast<BYTE>(alpha), GetRValue(color), GetGValue(color),
      GetBValue(color)));
  g.FillPath(&brush, path);
  delete path;
}

// 多层描边模拟的柔和投影（GDI+ 没有内置模糊）。
void DrawCardShadow(Gdiplus::Graphics& g, const Gdiplus::RectF& card,
                    float radius, int layers) {
  for (int i = layers; i >= 1; i--) {
    float grow = i * 1.6f;
    Gdiplus::RectF r(card.X - grow, card.Y - grow, card.Width + grow * 2,
                     card.Height + grow * 2);
    FillRound(g, r, radius + grow, RGB(16, 32, 31), 7);
  }
}

Gdiplus::Font* UiFont(float px, bool bold) {
  return new Gdiplus::Font(L"Microsoft YaHei UI", px, bold ? Gdiplus::FontStyleBold
                                                           : Gdiplus::FontStyleRegular,
                           Gdiplus::UnitPixel);
}

void DrawString(Gdiplus::Graphics& g, const std::wstring& text,
                const Gdiplus::RectF& rc, float px, bool bold, COLORREF color,
                Gdiplus::StringAlignment align = Gdiplus::StringAlignmentNear,
                bool ellipsis = true) {
  Gdiplus::Font* font = UiFont(px, bold);
  Gdiplus::SolidBrush brush(Gdiplus::Color(255, GetRValue(color),
                                           GetGValue(color), GetBValue(color)));
  Gdiplus::StringFormat format;
  format.SetAlignment(align);
  format.SetLineAlignment(Gdiplus::StringAlignmentNear);
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap |
                        Gdiplus::StringFormatFlagsLineLimit);
  if (ellipsis) format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  g.DrawString(text.c_str(), static_cast<INT>(text.size()), font, rc, &format,
               &brush);
  delete font;
}

// 多行文本（GDI+ 在布局矩形内自动换行），返回实际行数。
//
// **必须裁剪到布局矩形内**：GDI+ 的 DrawString 只在"行内"换行，超出矩形高度
// 的行会照常画下去。正文写的是"某某设备 想发送 N 个文件（大小）"——设备名一长
// 就是三四行，多出来的行直接盖在下面的「接收 / 忽略」按钮上，
// 用户看到的就是"通知的按钮被遮挡"。裁剪之后最多是文字被切掉，按钮永远干净。
int DrawWrapped(Gdiplus::Graphics& g, const std::wstring& text,
                const Gdiplus::RectF& rc, float px, bool bold, COLORREF color) {
  Gdiplus::Font* font = UiFont(px, bold);
  Gdiplus::SolidBrush brush(Gdiplus::Color(255, GetRValue(color),
                                           GetGValue(color), GetBValue(color)));
  Gdiplus::StringFormat format;
  format.SetLineAlignment(Gdiplus::StringAlignmentNear);
  g.SetClip(rc);
  g.DrawString(text.c_str(), static_cast<INT>(text.size()), font, rc, &format,
               &brush);
  g.ResetClip();
  delete font;
  return 2;  // 布局高度由调用方固定为两行。
}

// 通知卡片左上角的迷你图标：与应用图标同一套构图
// （青绿圆角文件卡 + 两条白线 + 珊瑚圆点），不再画纸飞机。
void DrawMiniIcon(Gdiplus::Graphics& g, const Gdiplus::RectF& rc) {
  const float s = rc.Height;
  Gdiplus::GraphicsPath* path = RoundedRect(rc, s * 0.30f);
  Gdiplus::LinearGradientBrush brush(
      rc, Gdiplus::Color(255, 58, 200, 203), Gdiplus::Color(255, 14, 124, 134),
      45.0f, false);
  g.FillPath(&brush, path);
  delete path;

  // 两条白色文字线。
  Gdiplus::SolidBrush white(Gdiplus::Color(235, 255, 255, 255));
  for (int i = 0; i < 2; i++) {
    float lw = s * (i == 0 ? 0.50f : 0.34f);
    float ly = rc.Y + s * (0.52f + i * 0.16f);
    Gdiplus::GraphicsPath* bar =
        RoundedRect(Gdiplus::RectF(rc.X + s * 0.22f, ly, lw, s * 0.085f),
                    s * 0.045f);
    g.FillPath(&white, bar);
    delete bar;
  }

  // 珊瑚圆点：正在移动的那份数据。
  Gdiplus::SolidBrush coral(Gdiplus::Color(255, 255, 122, 89));
  const float d = s * 0.20f;
  g.FillEllipse(&coral, rc.X + s * 0.66f, rc.Y + s * 0.14f, d, d);
}

// 渐变圆角按钮。font_px 已含 DPI 缩放（GDI+ 的 UnitPixel 是物理像素）。
void DrawButton(Gdiplus::Graphics& g, const Gdiplus::RectF& r, bool brand,
                const std::wstring& label, float font_px) {
  if (brand) {
    Gdiplus::GraphicsPath* path = RoundedRect(r, r.Height / 2);
    Gdiplus::LinearGradientBrush brush(
        r, Gdiplus::Color(255, 58, 200, 203), Gdiplus::Color(255, 14, 124, 134),
        90.0f, false);
    g.FillPath(&brush, path);
    delete path;
  } else {
    FillRound(g, r, r.Height / 2, kChipBg);
    // 细描边。
    Gdiplus::GraphicsPath* path = RoundedRect(r, r.Height / 2);
    Gdiplus::Pen pen(Gdiplus::Color(255, GetRValue(kLine), GetGValue(kLine),
                                    GetBValue(kLine)));
    g.DrawPath(&pen, path);
    delete path;
  }
  Gdiplus::Font* font = UiFont(font_px, true);
  Gdiplus::SolidBrush brush(brand ? Gdiplus::Color(255, 255, 255, 255)
                                  : Gdiplus::Color(255, GetRValue(kText),
                                                   GetGValue(kText),
                                                   GetBValue(kText)));
  Gdiplus::StringFormat format;
  format.SetAlignment(Gdiplus::StringAlignmentCenter);
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  g.DrawString(label.c_str(), static_cast<INT>(label.size()), font, r, &format,
               &brush);
  delete font;
}

}  // namespace

// 抓取窗口在屏幕上的真实像素，统计平均亮度与"接近纯黑"的占比。
// 用来客观判定"主窗口是不是黑屏"——用户能直接看见的故障，不能靠猜。
// 定义在文件后部（和绘制工具放在一起），这里先前置声明。
bool CaptureWindowStats(HWND hwnd, double* mean_out, double* dark_out,
                         const std::wstring& png_path);

// 拖动状态。
struct BallDragState {
  bool dragging = false;
  bool moved = false;
  bool started_expanded = false;  // 按下时是否已展开（区分把手点击与球点击）
  POINT down{};
  POINT start{};
};
BallDragState g_ball_drag;

// 气泡按钮命中区域（窗口客户区坐标）。
struct BubbleButtons {
  RECT primary{};
  RECT secondary{};
};
BubbleButtons g_bubble_buttons;

// 通知卡片按钮命中区域。
struct ToastButtons {
  RECT card{};
  RECT primary{};
  RECT secondary{};
};
ToastButtons g_toast_buttons;

// ---------------------------------------------------------------------------
// 悬浮球窗口过程
// ---------------------------------------------------------------------------

LRESULT CALLBACK BallWndProc(HWND hwnd, UINT message, WPARAM wparam,
                             LPARAM lparam) {
  switch (message) {
    case WM_MOUSEMOVE: {
      FlutterWindow* w = g_instance;
      if (w == nullptr || w->ball_window_ != hwnd) break;
      // 光标在球上就是"有焦点"：取消空闲计时，半透明的立刻恢复不透明。
      w->NoteBallActivity();
      if (g_ball_drag.dragging) {
        POINT now;
        GetCursorPos(&now);
        int dx = now.x - g_ball_drag.down.x;
        int dy = now.y - g_ball_drag.down.y;
        if (abs(dx) + abs(dy) > 4) g_ball_drag.moved = true;
        if (g_ball_drag.moved) {
          int x = g_ball_drag.start.x + dx;
          int y = g_ball_drag.start.y + dy;
          SetWindowPos(hwnd, nullptr, x, y, 0, 0,
                       SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
          w->ball_free_pos_ = POINT{x, y};
        }
      } else {
        if (!w->ball_expanded_ && w->ball_snapped_) {
          // 把手上悬停：先给一点放大反馈（光标一到位就有回应），
          // 再按设置的延时真正展开。以前是"等 300ms 然后突然长出来"。
          if (w->ball_anim_kind_ == 0 && w->ball_peek_ < 0.999f) {
            w->StartBallAnim(kBallAnimPeekIn);
          }
          if (w->ball_hover_timer_ == 0) {
            w->ball_hover_timer_ = SetTimer(hwnd, kBallHoverTimerId,
                                            w->ball_hover_delay_ms_, nullptr);
          }
        }
        if (w->ball_expanded_) {
          // 鼠标在球上：别让它自动缩回去。
          KillTimer(hwnd, kBallCollapseTimerId);
          w->ball_collapse_timer_ = 0;
          KillTimer(hwnd, kBallLeaveTimerId);
          w->ball_leave_timer_ = 0;
        }
        if (!w->ball_hover_tracked_) {
          TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, hwnd, 0};
          TrackMouseEvent(&track);
          w->ball_hover_tracked_ = true;
        }
      }
      return 0;
    }

    case WM_MOUSELEAVE: {
      FlutterWindow* w = g_instance;
      if (w == nullptr || w->ball_window_ != hwnd) break;
      w->ball_hover_tracked_ = false;
      KillTimer(hwnd, kBallHoverTimerId);
      w->ball_hover_timer_ = 0;
      // 光标走了、还没展开：把刚才的放大反馈收回去。
      if (!w->ball_expanded_ && w->ball_peek_ > 0.001f &&
          w->ball_anim_kind_ != kBallAnimExpand) {
        w->StartBallAnim(kBallAnimPeekOut);
      }
      // 鼠标离开球：稍后缩回把手。
      //
      // 展开动画还没走完也要排上——否则"悬停一下马上走开"会让球停在展开态
      // 直到 3 秒自动收起，看着像没反应。动画没结束时定时器会自己续期。
      if (w->ball_snapped_ &&
          (w->ball_expanded_ || w->ball_anim_kind_ == kBallAnimExpand)) {
        KillTimer(hwnd, kBallLeaveTimerId);
        w->ball_leave_timer_ = SetTimer(hwnd, kBallLeaveTimerId, 700, nullptr);
      }
      // 失去"焦点"：1s 后开始慢慢变暗（见 ScheduleBallIdle）。
      w->ScheduleBallIdle();
      return 0;
    }

    case WM_LBUTTONDOWN: {
      g_ball_drag.dragging = true;
      g_ball_drag.moved = false;
      FlutterWindow* w = g_instance;
      g_ball_drag.started_expanded = w != nullptr && w->ball_expanded_;
      GetCursorPos(&g_ball_drag.down);
      RECT wr;
      GetWindowRect(hwnd, &wr);
      g_ball_drag.start = POINT{wr.left, wr.top};
      SetCapture(hwnd);
      if (w != nullptr) {
        KillTimer(hwnd, kBallHoverTimerId);
        w->ball_hover_timer_ = 0;
        KillTimer(hwnd, kBallLeaveTimerId);
        w->ball_leave_timer_ = 0;
        KillTimer(hwnd, kBallCollapseTimerId);
        w->ball_collapse_timer_ = 0;
        // 上一次吸附滑行还没走完就被重新按住：立刻停住，别跟手抢位置。
        if (w->ball_snap_timer_ != 0) {
          KillTimer(hwnd, kBallSnapTimerId);
          w->ball_snap_timer_ = 0;
        }
        // 从把手直接拖动时：让球"长"出来，而不是啪地换成完整球。
        if (!w->ball_expanded_) w->ExpandBall(true);
      }
      return 0;
    }

    case WM_LBUTTONUP: {
      if (!g_ball_drag.dragging) break;
      g_ball_drag.dragging = false;
      ReleaseCapture();
      FlutterWindow* w = g_instance;
      if (w == nullptr) return 0;
      if (g_ball_drag.moved) {
        w->SnapBallToEdge();
      } else if (g_ball_drag.started_expanded) {
        // 单击球体：让 Dart 决定弹什么气泡（它才知道当前的请求内容）。
        // 从把手上点开的（按下时还是把手）不算单击球体。
        w->InvokeDart("onBallClicked", flutter::EncodableMap{});
      }
      return 0;
    }

    case WM_TIMER: {
      FlutterWindow* w = g_instance;
      if (w == nullptr || w->ball_window_ != hwnd) break;
      if (wparam == kBallAnimTimerId) {
        w->StepBallAnim();
        return 0;
      }
      if (wparam == kBallSnapTimerId) {
        w->StepBallSnap();
        return 0;
      }
      if (wparam == kBallDimTimerId) {
        w->StepBallDim();
        return 0;
      }
      if (wparam == kBallIdleTimerId) {
        KillTimer(hwnd, kBallIdleTimerId);
        w->ball_idle_timer_ = 0;
        // 提示/气泡在的时候不算空闲：那是用户正在看的东西，不能淡。
        if (!w->bubble_active_ && w->ball_anim_kind_ != kBallAnimAlert) {
          w->StartBallDim(true);
        }
        return 0;
      }
      if (wparam == kBallTopTimerId) {
        w->UpdateBallTopmost();
        return 0;
      }
      if (wparam == kBallHoverTimerId) {
        KillTimer(hwnd, kBallHoverTimerId);
        w->ball_hover_timer_ = 0;
        if (!w->ball_expanded_) w->ExpandBall(true);
        return 0;
      }
      if (wparam == kBallCollapseTimerId || wparam == kBallLeaveTimerId) {
        KillTimer(hwnd, wparam);
        if (w->ball_collapse_timer_ == wparam) w->ball_collapse_timer_ = 0;
        if (w->ball_leave_timer_ == wparam) w->ball_leave_timer_ = 0;
        if (w->ball_snapped_ && w->ball_expanded_) {
          if (w->ball_anim_kind_ != 0) {
            // 动画还没走完（展开/提示中）：过一会儿再收，别把"该收"这件事丢了。
            w->ball_leave_timer_ =
                SetTimer(hwnd, kBallLeaveTimerId, 200, nullptr);
          } else {
            w->CollapseBall();
          }
        }
        return 0;
      }
      break;
    }
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

// ---------------------------------------------------------------------------
// 气泡窗口过程
// ---------------------------------------------------------------------------

LRESULT CALLBACK BubbleWndProc(HWND hwnd, UINT message, WPARAM wparam,
                               LPARAM lparam) {
  switch (message) {
    case WM_LBUTTONUP: {
      POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (g_instance != nullptr) g_instance->HandleBubbleClick(pt);
      return 0;
    }
    case WM_TIMER:
      if (wparam == kBubbleAnimTimerId) {
        if (g_instance != nullptr) g_instance->StepBubbleAnim();
        return 0;
      }
      if (wparam == kBubbleTimeoutTimerId) {
        KillTimer(hwnd, kBubbleTimeoutTimerId);
        if (g_instance != nullptr) {
          g_instance->HideBubble();
          // 取消提示的超时只是"看完自动收"，不算询问超时——
          // 不能触发 onBubbleTimeout，否则 Dart 会误以为询问被晾过。
          if (g_instance->bubble_mode_ != kCardModeCanceled) {
            g_instance->InvokeDart("onBubbleTimeout", flutter::EncodableMap{});
          }
        }
        return 0;
      }
      break;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

// ---------------------------------------------------------------------------
// 通知卡片窗口过程
// ---------------------------------------------------------------------------

LRESULT CALLBACK ToastWndProc(HWND hwnd, UINT message, WPARAM wparam,
                              LPARAM lparam) {
  switch (message) {
    case WM_LBUTTONUP: {
      POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (g_instance != nullptr) g_instance->HandleToastClick(pt);
      return 0;
    }
    case WM_TIMER: {
      FlutterWindow* w = g_instance;
      if (w == nullptr || w->toast_window_ != hwnd) break;
      if (wparam == kToastAnimTimerId) {
        // 按时间求进度、缓出：起手快、收尾轻，位置不动。
        const float t = Clamp01((GetTickCount64() - w->toast_anim_start_) /
                                static_cast<float>(kToastFadeMs));
        w->RenderToast(kToastFadeStart +
                       (1.0f - kToastFadeStart) * EaseOutCubic(t));
        if (t >= 1.0f) {
          KillTimer(hwnd, kToastAnimTimerId);
          w->toast_anim_timer_ = 0;
          w->RenderToast(1.0f);
        }
        return 0;
      }
      if (wparam == kToastTimeoutTimerId) {
        KillTimer(hwnd, kToastTimeoutTimerId);
        w->toast_timeout_timer_ = 0;
        w->HideToast();
        return 0;
      }
      break;
    }
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

// ---------------------------------------------------------------------------
// FlutterWindow
// ---------------------------------------------------------------------------

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {
  g_instance = this;
}

FlutterWindow::~FlutterWindow() {
  if (g_instance == this) g_instance = nullptr;
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // 先把窗口摆到该在的位置（记忆的位置 / 首次启动的竖屏居中），
  // 再按最终客户区尺寸创建引擎视图——顺序反了会先按 1280×720 建一次表面，
  // 再缩到竖屏，白闪一帧。
  ApplyWindowPlacement();

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "wisp/desktop",
          &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& name = call.method_name();
        const flutter::EncodableValue* arguments = call.arguments();
        const auto* map =
            arguments != nullptr
                ? std::get_if<flutter::EncodableMap>(
                      static_cast<const flutter::internal::EncodableValueVariant*>(
                          arguments))
                : nullptr;

        auto GetString = [&](const char* key) -> std::wstring {
          if (map == nullptr) return L"";
          auto entry = map->find(flutter::EncodableValue(key));
          if (entry == map->end()) return L"";
          const auto* value = std::get_if<std::string>(
              static_cast<const flutter::internal::EncodableValueVariant*>(
                  &entry->second));
          if (value == nullptr) return L"";
          int size = MultiByteToWideChar(CP_UTF8, 0, value->c_str(),
                                         static_cast<int>(value->size()),
                                         nullptr, 0);
          std::wstring wide(size, L'\0');
          MultiByteToWideChar(CP_UTF8, 0, value->c_str(),
                              static_cast<int>(value->size()), wide.data(), size);
          return wide;
        };
        auto GetBool = [&](const char* key, bool fallback) -> bool {
          if (map == nullptr) return fallback;
          auto entry = map->find(flutter::EncodableValue(key));
          if (entry == map->end()) return fallback;
          const auto* value = std::get_if<bool>(
              static_cast<const flutter::internal::EncodableValueVariant*>(
                  &entry->second));
          return value != nullptr ? *value : fallback;
        };
        auto GetInt = [&](const char* key, int fallback) -> int {
          if (map == nullptr) return fallback;
          auto entry = map->find(flutter::EncodableValue(key));
          if (entry == map->end()) return fallback;
          const auto* value = std::get_if<int32_t>(
              static_cast<const flutter::internal::EncodableValueVariant*>(
                  &entry->second));
          if (value != nullptr) return *value;
          const auto* long_value = std::get_if<int64_t>(
              static_cast<const flutter::internal::EncodableValueVariant*>(
                  &entry->second));
          return long_value != nullptr ? static_cast<int>(*long_value) : fallback;
        };

        if (name == "setMinimizeToTray") {
          minimize_to_tray_ = GetBool("enabled", true);
          result->Success();
        } else if (name == "setStartupVisible") {
          // Dart 读完设置后的表态：这次启动要不要显示主窗口（静默启动 = false）。
          // 表态一次就够，之后再调只当作"显示/隐藏主窗口"用。
          const bool visible = GetBool("visible", true);
          startup_decided_ = true;
          startup_visible_ = visible;
          KillTimer(GetHandle(), kStartupTimerId);
          startup_timer_ = 0;
          // 静默启动时窗口永远不显示，也就不会有 WM_SHOWWINDOW 触发推送。
          // 这里必须主动推一次——而且正是"用户此刻刚说完话、Dart 侧一定在听"的
          // 时机，比启动时那条更可靠。不推的话 Dart 会以为窗口还开着，
          // 雷达动画在托盘里空转到关机。
          NotifyWindowVisibility(true);
          if (visible) {
            MaybeShowOnStartup();
          }
          result->Success();
        } else if (name == "isWindowVisible") {
          result->Success(GetHandle() != nullptr && IsWindowVisible(GetHandle()));
        } else if (name == "windowState") {
          // 通知分流要用的是"可见 + 是否为当前激活窗口"两个维度：
          // 窗口可见但被别的程序盖住时，桌面通知照样得弹。
          HWND main = GetHandle();
          const bool visible = main != nullptr && IsWindowVisible(main);
          const bool active = main != nullptr && GetForegroundWindow() == main;
          flutter::EncodableMap state{
              {flutter::EncodableValue("visible"), flutter::EncodableValue(visible)},
              {flutter::EncodableValue("active"), flutter::EncodableValue(active)},
              {flutter::EncodableValue("ballEnabled"),
               flutter::EncodableValue(ball_window_ != nullptr)},
              {flutter::EncodableValue("ballExpanded"),
               flutter::EncodableValue(ball_expanded_)},
              {flutter::EncodableValue("ballSnapped"),
               flutter::EncodableValue(ball_snapped_)},
          };
          result->Success(state);
        } else if (name == "debugWindows") {
          // 自测入口用：一次性拿到三类桌面窗口的可见性与屏幕矩形。
          auto describe = [](HWND hwnd) {
            flutter::EncodableMap m{
                {flutter::EncodableValue("exists"),
                 flutter::EncodableValue(hwnd != nullptr)},
                {flutter::EncodableValue("visible"),
                 flutter::EncodableValue(hwnd != nullptr &&
                                         IsWindowVisible(hwnd) != 0)},
            };
            RECT r{0, 0, 0, 0};
            if (hwnd != nullptr) GetWindowRect(hwnd, &r);
            m[flutter::EncodableValue("left")] = flutter::EncodableValue(static_cast<int>(r.left));
            m[flutter::EncodableValue("top")] = flutter::EncodableValue(static_cast<int>(r.top));
            m[flutter::EncodableValue("right")] = flutter::EncodableValue(static_cast<int>(r.right));
            m[flutter::EncodableValue("bottom")] = flutter::EncodableValue(static_cast<int>(r.bottom));
            return m;
          };
          RECT work = BallWorkArea();
          flutter::EncodableMap all{
              {flutter::EncodableValue("toast"), flutter::EncodableValue(describe(toast_window_))},
              {flutter::EncodableValue("bubble"), flutter::EncodableValue(describe(bubble_window_))},
              {flutter::EncodableValue("ball"), flutter::EncodableValue(describe(ball_window_))},
              {flutter::EncodableValue("workLeft"), flutter::EncodableValue(static_cast<int>(work.left))},
              {flutter::EncodableValue("workTop"), flutter::EncodableValue(static_cast<int>(work.top))},
              {flutter::EncodableValue("workRight"), flutter::EncodableValue(static_cast<int>(work.right))},
              {flutter::EncodableValue("workBottom"), flutter::EncodableValue(static_cast<int>(work.bottom))},
          };
          result->Success(all);
        } else if (name == "showWindow") {
          RestoreWindow();
          result->Success();
        } else if (name == "isSupported") {
          result->Success(true);
        } else if (name == "serviceStatus") {
          // 0=未安装 1=已安装未运行 2=运行中。
          result->Success(KeepAliveServiceStatus());
        } else if (name == "installService") {
          result->Success(InstallKeepAliveService());
        } else if (name == "uninstallService") {
          result->Success(UninstallKeepAliveService());
        } else if (name == "restartService") {
          result->Success(RestartKeepAliveService());
        } else if (name == "setTrayFlashing") {
          SetTrayFlashing(GetBool("enabled", false));
          result->Success();
        } else if (name == "showToast") {
          ShowToast(GetString("title"), GetString("body"), GetInt("mode", 0),
                    GetString("progress"));
          result->Success();
        } else if (name == "updateToast") {
          UpdateToast(GetString("body"), GetInt("mode", 0),
                      GetString("progress"));
          result->Success();
        } else if (name == "hideToast") {
          HideToast();
          result->Success();
        } else if (name == "setFloatingBall") {
          // 恢复上次记忆的球位置（无记录时原生层用默认右下角）。
          auto HasKey = [&](const char* key) -> bool {
            return map != nullptr &&
                   map->find(flutter::EncodableValue(key)) != map->end();
          };
          if (HasKey("x") && HasKey("y")) {
            ball_saved_pos_ = POINT{GetInt("x", -1), GetInt("y", -1)};
            ball_saved_snapped_ = GetBool("snapped", false);
            ball_saved_edge_ = GetInt("edge", -1);
          } else {
            ball_saved_pos_ = POINT{-1, -1};
          }
          SetFloatingBall(GetBool("enabled", false),
                          GetInt("hoverDelayMs", 300));
          result->Success();
        } else if (name == "showBallAlert") {
          ShowBallAlert();
          result->Success();
        } else if (name == "collapseBall") {
          // 通知流程结束：吸附状态的球缩回把手。
          if (ball_snapped_ && ball_expanded_) CollapseBall();
          result->Success();
        } else if (name == "showBubble") {
          ShowBubble(GetString("title"), GetString("body"), GetInt("mode", 0),
                     GetString("progress"));
          result->Success();
        } else if (name == "updateBubble") {
          UpdateBubble(GetString("body"), GetInt("mode", 0),
                       GetString("progress"));
          result->Success();
        } else if (name == "hideBubble") {
          HideBubble();
          result->Success();
        } else if (name == "openUrl") {
          // 打开下载链接。返回 true/false，Dart 侧据此提示失败原因。
          result->Success(OpenUrl(GetString("url")) == 0);
        } else if (name == "runInstaller") {
          // 启动下载好的安装程序（自动更新）。返回 true/false。
          result->Success(
              RunInstaller(GetString("path"), GetString("args")));
        } else if (name == "surfaceStatus") {
          // 桌面浮层的真实状态：Dart 侧用它确认"通知真的出来了"，
          // 没出来就重发一次——解决"第一次不出现、第二次才出现"。
          auto describe = [](HWND hwnd, bool active, bool drawn) {
            flutter::EncodableMap m{
                {flutter::EncodableValue("visible"),
                 flutter::EncodableValue(hwnd != nullptr &&
                                         IsWindowVisible(hwnd) != 0)},
                {flutter::EncodableValue("active"),
                 flutter::EncodableValue(active)},
                {flutter::EncodableValue("drawn"),
                 flutter::EncodableValue(drawn)},
            };
            RECT r{0, 0, 0, 0};
            if (hwnd != nullptr) GetWindowRect(hwnd, &r);
            m[flutter::EncodableValue("left")] =
                flutter::EncodableValue(static_cast<int>(r.left));
            m[flutter::EncodableValue("top")] =
                flutter::EncodableValue(static_cast<int>(r.top));
            m[flutter::EncodableValue("right")] =
                flutter::EncodableValue(static_cast<int>(r.right));
            m[flutter::EncodableValue("bottom")] =
                flutter::EncodableValue(static_cast<int>(r.bottom));
            return m;
          };
          flutter::EncodableMap m{
              {flutter::EncodableValue("toast"),
               flutter::EncodableValue(describe(toast_window_, toast_active_,
                                                 toast_drawn_))},
              {flutter::EncodableValue("bubble"),
               flutter::EncodableValue(describe(bubble_window_, bubble_active_,
                                                 bubble_drawn_))},
          };
          result->Success(m);
        } else if (name == "debugSetMainVisible") {
          // 自测用：把主窗口隐藏/显示出来，复现"托盘态收到请求"这类场景。
          const bool visible = GetBool("visible", true);
          HWND main = GetHandle();
          if (main != nullptr) {
            ShowWindow(main, visible ? SW_SHOWNORMAL : SW_HIDE);
          }
          result->Success();
        } else if (name == "debugFocusMain") {
          // 自测用：把主窗口置前（模拟用户点回主窗口）。
          HWND main = GetHandle();
          if (main != nullptr) {
            ShowWindow(main, SW_SHOW);
            SetForegroundWindow(main);
          }
          result->Success();
        } else if (name == "debugBlurMain") {
          // 自测用：把焦点挪到别的窗口（模拟主窗口开着但用户忙别的）。
          HWND main = GetHandle();
          HWND other = GetDesktopWindow();
          if (main != nullptr && other != nullptr) {
            SetForegroundWindow(other);
          }
          result->Success();
        } else if (name == "debugCapture") {
          // 自测用：抓某个窗口的屏幕像素，返回 {ok, mean, dark}，
          // 同时在 exe 同目录存一张 PNG 供人眼核对。
          const std::wstring target = GetString("target");
          HWND target_hwnd = GetHandle();
          std::wstring tag = L"main";
          if (target == L"toast") {
            target_hwnd = toast_window_;
            tag = L"toast";
          } else if (target == L"bubble") {
            target_hwnd = bubble_window_;
            tag = L"bubble";
          }
          double mean = 0;
          double dark = 0;
          std::wstring png;
          if (target_hwnd != nullptr) {
            char exe_path[MAX_PATH];
            GetModuleFileNameA(nullptr, exe_path, MAX_PATH);
            std::string dir(exe_path);
            const size_t slash = dir.find_last_of("\\/");
            if (slash != std::string::npos) dir = dir.substr(0, slash + 1);
            png = L"wisp_shot_";
            png += tag;
            png += L".png";
            std::wstring full;
            const int n = MultiByteToWideChar(CP_UTF8, 0, dir.c_str(),
                                             static_cast<int>(dir.size()),
                                             nullptr, 0);
            if (n > 0) {
              full.resize(static_cast<size_t>(n));
              MultiByteToWideChar(CP_UTF8, 0, dir.c_str(),
                                  static_cast<int>(dir.size()), full.data(), n);
            }
            full += png;
            png = full;
          }
          const bool ok = CaptureWindowStats(target_hwnd, &mean, &dark, png);
          flutter::EncodableMap m{
              {flutter::EncodableValue("ok"), flutter::EncodableValue(ok)},
              {flutter::EncodableValue("mean"), flutter::EncodableValue(mean)},
              {flutter::EncodableValue("dark"), flutter::EncodableValue(dark)},
              {flutter::EncodableValue("png"), flutter::EncodableValue("")},
          };
          result->Success(m);
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // 如果用户在首帧渲染完成之前就点了关闭，别再把窗口弹回来。
    if (close_requested_) return;
    // 首帧好了，但还不显示：等 Dart 读完设置说"这次要不要露面"。
    // 静默启动是 Dart 侧的用户设置，原生层先显示再隐藏会闪一下。
    first_frame_ready_ = true;
    MaybeShowOnStartup();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  CreateTrayIcon();
  EnsureGdiplus();
  // 通知卡和气泡的窗口在启动时就建好（保持隐藏）：第一次弹的时候不用现创建，
  // 少一个"首次创建状态不对"的机会——用户反馈过"第一次不出现、第二次才出现"。
  CreateToastWindow();
  CreateBubbleWindow();

  // 拖拽发送：主窗口注册为拖放目标，文件/文件夹拖进来就加入待发清单。
  // 子窗口（Flutter 视图）没注册也没关系，Shell 会沿父链找到这个顶层窗口。
  DragAcceptFiles(GetHandle(), TRUE);

  // Dart 迟迟不表态（设置读失败、通道异常）时的兜底：照常显示窗口。
  // 宁可多弹一次，也不能让应用启动之后什么都不发生。
  KillTimer(GetHandle(), kStartupTimerId);
  startup_timer_ =
      SetTimer(GetHandle(), kStartupTimerId, kStartupFallbackMs, nullptr);

  return true;
}

void FlutterWindow::OnDestroy() {
  DestroyTrayIcon();
  DestroyBallWindow();
  DestroyBubbleWindow();
  DestroyToastWindow();
  ShutdownGdiplus();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

// ---------------------------------------------------------------------------
// 启动可见性（静默启动）
// ---------------------------------------------------------------------------

void FlutterWindow::MaybeShowOnStartup(bool force) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || shown_once_ || close_requested_) return;
  // 三件事都齐了才显示：首帧画好了（不然会先闪一帧白）、Dart 表态了、
  // 用户这次确实要看到窗口。
  if (!force && !first_frame_ready_) return;
  if (!startup_decided_ || !startup_visible_) return;

  shown_once_ = true;
  Show();
  // 记忆里是最大化：显示之后再展开，避免"先小窗口再跳大"。
  if (placement_maximized_) {
    ShowWindow(hwnd, SW_MAXIMIZE);
  }
  NotifyWindowVisibility();
}

// ---------------------------------------------------------------------------
// 窗口可见性
// ---------------------------------------------------------------------------

void FlutterWindow::NotifyWindowVisibility(bool force, int visible_hint) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || channel_ == nullptr) return;
  // 最小化也算"用户看不见"：窗口还在，引擎也还在出帧，但屏幕上没有它。
  // 只判 IsWindowVisible 会让"最小化到任务栏"这条路径继续空转。
  const bool visible =
      visible_hint >= 0
          ? visible_hint != 0
          : (IsWindowVisible(hwnd) != FALSE && IsIconic(hwnd) == FALSE);
  if (!force && visible == last_window_visible_) return;
  last_window_visible_ = visible;
  InvokeDart("onWindowVisibility",
             flutter::EncodableMap{
                 {flutter::EncodableValue("visible"),
                  flutter::EncodableValue(visible)}});
}

// ---------------------------------------------------------------------------
// 主窗口尺寸/位置记忆
// ---------------------------------------------------------------------------

namespace {

// 记忆记录的版本标记。字段顺序变了就换一个，读到旧格式直接当没有记录。
constexpr DWORD kPlacementMagic = 0x31535757;  // 'WWS1'
constexpr wchar_t kPlacementSubKey[] = L"Software\\Wisp";
constexpr wchar_t kPlacementValueName[] = L"WindowPlacement";

struct WindowPlacementRecord {
  DWORD magic;
  LONG left;
  LONG top;
  LONG right;
  LONG bottom;
  DWORD maximized;
};

// 记忆的矩形是否还落在某台显示器上。
//
// 拔掉副屏、改分辨率、换缩放之后，原来的坐标可能落在"不存在的桌面"里，
// 照原样恢复等于窗口在屏幕外——用户看到的就是"启动了但界面不见了"。
bool RectOnAnyMonitor(const RECT& rc) {
  if (rc.right - rc.left < 80 || rc.bottom - rc.top < 80) return false;
  HMONITOR mon = MonitorFromRect(&rc, MONITOR_DEFAULTTONULL);
  if (mon == nullptr) return false;
  MONITORINFO mi{sizeof(MONITORINFO)};
  if (!GetMonitorInfoW(mon, &mi)) return false;
  RECT hit{};
  if (!IntersectRect(&hit, &rc, &mi.rcMonitor)) return false;
  // 至少要有一小块（标题栏范围）在屏幕上，才谈得上"能拖回来"。
  return (hit.right - hit.left) >= 80 && (hit.bottom - hit.top) >= 48;
}

}  // namespace

void FlutterWindow::ApplyWindowPlacement() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) return;

  WindowPlacementRecord rec{};
  DWORD size = sizeof(rec);
  DWORD type = 0;
  const LONG read = RegGetValueW(HKEY_CURRENT_USER, kPlacementSubKey,
                                 kPlacementValueName, RRF_RT_REG_BINARY, &type,
                                 &rec, &size);
  if (read == ERROR_SUCCESS && size == sizeof(rec) &&
      rec.magic == kPlacementMagic) {
    const RECT saved{rec.left, rec.top, rec.right, rec.bottom};
    if (RectOnAnyMonitor(saved)) {
      const int w = static_cast<int>(saved.right - saved.left);
      const int h = static_cast<int>(saved.bottom - saved.top);
      SetWindowPos(hwnd, nullptr, static_cast<int>(saved.left),
                   static_cast<int>(saved.top), w, h,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      last_normal_rect_ = saved;
      placement_maximized_ = rec.maximized != 0;
      return;
    }
  }

  // 没有记忆（首次安装）：竖屏、居中。
  RECT work{};
  HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO mi{sizeof(MONITORINFO)};
  if (mon != nullptr && GetMonitorInfoW(mon, &mi)) {
    work = mi.rcWork;
  } else {
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  }
  const int work_w = static_cast<int>(work.right - work.left);
  const int work_h = static_cast<int>(work.bottom - work.top);
  int w = ScaleFor(hwnd, kDefaultWindowWidth);
  int h = ScaleFor(hwnd, kDefaultWindowHeight);
  // 小屏兜底：留出约 8% 的余量，并且保证仍然是竖屏（高 > 宽）。
  const int cap_w = work_w - work_w / 12;
  const int cap_h = work_h - work_h / 12;
  if (w > cap_w) w = cap_w;
  if (h > cap_h) h = cap_h;
  if (w >= h) w = h * 5 / 8;
  const int x = static_cast<int>(work.left) + (work_w - w) / 2;
  const int y = static_cast<int>(work.top) + (work_h - h) / 2;
  SetWindowPos(hwnd, nullptr, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
  last_normal_rect_ = RECT{x, y, x + w, y + h};
  placement_maximized_ = false;
}

void FlutterWindow::SaveWindowPlacement() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) return;

  // 只记"正常态"矩形：最大化时的 GetWindowRect 是整块屏幕，记下来下次
  // 取消最大化就回不到原来的大小了。
  if (!IsIconic(hwnd) && !IsZoomed(hwnd)) {
    RECT rc{};
    if (GetWindowRect(hwnd, &rc)) last_normal_rect_ = rc;
  }
  if (last_normal_rect_.right - last_normal_rect_.left < 80) return;

  WindowPlacementRecord rec{};
  rec.magic = kPlacementMagic;
  rec.left = last_normal_rect_.left;
  rec.top = last_normal_rect_.top;
  rec.right = last_normal_rect_.right;
  rec.bottom = last_normal_rect_.bottom;
  rec.maximized = IsZoomed(hwnd) ? 1 : 0;

  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kPlacementSubKey, 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return;
  }
  RegSetValueExW(key, kPlacementValueName, 0, REG_BINARY,
                 reinterpret_cast<const BYTE*>(&rec), sizeof(rec));
  RegCloseKey(key);
}

// ---------------------------------------------------------------------------
// 托盘
// ---------------------------------------------------------------------------

void FlutterWindow::CreateTrayIcon() {
  tray_data_ = {};
  tray_data_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_data_.hWnd = GetHandle();
  tray_data_.uID = 1;
  tray_data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_data_.uCallbackMessage = kTrayMessage;
  tray_data_.hIcon = LoadAppIcon();
  wcscpy_s(tray_data_.szTip, L"Wisp — 局域网传输");

  if (Shell_NotifyIconW(NIM_ADD, &tray_data_)) {
    tray_visible_ = true;
  }
}

void FlutterWindow::DestroyTrayIcon() {
  SetTrayFlashing(false);
  if (!tray_visible_) {
    return;
  }
  Shell_NotifyIconW(NIM_DELETE, &tray_data_);
  tray_visible_ = false;
}

void FlutterWindow::SetTrayFlashing(bool flashing) {
  if (flashing == flashing_) return;
  flashing_ = flashing;
  if (flash_timer_ != 0) {
    KillTimer(GetHandle(), flash_timer_);
    flash_timer_ = 0;
  }
  if (!tray_visible_) return;

  if (flashing) {
    flash_frame_ = 0;
    flash_timer_ = SetTimer(GetHandle(), kFlashTimerId, 120, nullptr);
  } else {
    tray_data_.hIcon = LoadAppIcon();
    Shell_NotifyIconW(NIM_MODIFY, &tray_data_);
  }
}

// ---------------------------------------------------------------------------
// 悬浮球
// ---------------------------------------------------------------------------

void FlutterWindow::SetFloatingBall(bool enabled, int hover_delay_ms) {
  ball_hover_delay_ms_ = hover_delay_ms < 0 ? 0 : hover_delay_ms;
  if (enabled && ball_window_ == nullptr) {
    CreateBallWindow();
  } else if (!enabled) {
    HideBubble();
    DestroyBallWindow();
  }
}

void FlutterWindow::CreateBallWindow() {
  HINSTANCE instance = GetModuleHandle(nullptr);

  WNDCLASSW wc{};
  wc.lpfnWndProc = BallWndProc;
  wc.hInstance = instance;
  wc.lpszClassName = kBallClass;
  wc.hCursor = LoadCursor(nullptr, IDC_HAND);
  RegisterClassW(&wc);

  int size = ScaleFor(GetHandle(), kBallWindow);

  // 恢复上次的位置。这里有一条**必须**遵守的约束：
  // 「吸附」不只是"缩回把手"的开关，它同时承诺"这个把手正贴在屏幕边上"。
  // 以前这里直接信任记忆里的 x/y + snapped 标志，于是记忆坐标一旦失效
  // （换了缩放比例、拔了副屏、SPI_GETWORKAREA 把副屏上的球夹回主屏），
  // 就会得到一个"飘在屏幕中间、却按吸附逻辑缩成把手"的东西——
  // 用户看到的就是「明明没在屏幕边缘，却隐藏成把手了」。
  //
  // 所以吸附状态一律**按当前显示器工作区重新推导坐标**，而不是信任记忆值；
  // 推导不出来就老老实实当自由球，不进入缩回流程。
  const bool has_saved = ball_saved_pos_.x >= 0 && ball_saved_pos_.y >= 0;
  POINT anchor = has_saved ? ball_saved_pos_ : POINT{-1, -1};
  RECT work{};
  if (has_saved) {
    // 用记忆点所在的显示器：球拖到副屏时不能拿主屏工作区去夹。
    HMONITOR mon = MonitorFromPoint(anchor, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi{sizeof(MONITORINFO)};
    if (mon != nullptr && GetMonitorInfoW(mon, &mi)) {
      work = mi.rcWork;
    }
  }
  if (work.right - work.left <= 0) {
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  }

  int x;
  int y;
  bool snapped = false;
  int edge = -1;
  if (has_saved && ball_saved_snapped_ && ball_saved_edge_ >= 0 &&
      ball_saved_edge_ <= 3) {
    // 沿边方向的坐标沿用记忆，垂直于边的坐标按工作区重新算——这一步就是
    // "贴边"的保证，和 SnapBallToEdge 里完全一致（inset 为 0）。
    edge = ball_saved_edge_;
    switch (edge) {
      case 0:  // 左
        x = work.left;
        y = anchor.y;
        break;
      case 1:  // 右
        x = work.right - size;
        y = anchor.y;
        break;
      case 2:  // 上
        x = anchor.x;
        y = work.top;
        break;
      default:  // 下
        x = anchor.x;
        y = work.bottom - size;
        break;
    }
    if (edge == 0 || edge == 1) {
      if (y < work.top) y = work.top;
      if (y + size > work.bottom) y = work.bottom - size;
    } else {
      if (x < work.left) x = work.left;
      if (x + size > work.right) x = work.right - size;
    }
    // 推导完再验一遍：真的贴住了才算吸附，否则退回自由球（宁可显示成球，
    // 也不要出现一个悬在半空的把手）。
    const bool flush = (edge == 0 && x <= work.left + 1) ||
                       (edge == 1 && x + size >= work.right - 1) ||
                       (edge == 2 && y <= work.top + 1) ||
                       (edge == 3 && y + size >= work.bottom - 1);
    snapped = flush;
    if (!snapped) edge = -1;
  } else if (has_saved) {
    x = anchor.x;
    y = anchor.y;
    // 夹回工作区，防止显示器分辨率变化后球跑出屏幕。
    if (x + size > work.right) x = work.right - size;
    if (y + size > work.bottom) y = work.bottom - size;
    if (x < work.left) x = work.left;
    if (y < work.top) y = work.top;
  } else {
    x = work.right - size - ScaleFor(GetHandle(), 24);
    y = work.bottom - size - ScaleFor(GetHandle(), 140);
  }
  ball_free_pos_ = POINT{x, y};

  ball_window_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kBallClass, L"", WS_POPUP, x, y, size, size, nullptr, nullptr, instance,
      nullptr);
  if (ball_window_ == nullptr) return;

  ball_snapped_ = snapped;
  ball_edge_ = snapped ? edge : 1;
  ball_expanded_ = true;
  ball_t_ = 1.0f;
  // 新窗口是全不透明的；置顶守护从这里开始轮询。
  ball_dim_ = 1.0f;
  ball_dim_from_ = 1.0f;
  ball_dim_to_ = 1.0f;
  ball_hidden_by_fullscreen_ = false;
  ball_last_foreground_ = GetForegroundWindow();
  KillTimer(ball_window_, kBallTopTimerId);
  ball_top_timer_ =
      SetTimer(ball_window_, kBallTopTimerId, kBallTopPollMs, nullptr);
  RenderBall(1, 255, 1.0f);
  ShowWindow(ball_window_, SW_SHOWNOACTIVATE);
  // 恢复的是吸附位置：展开展示几秒后照常缩回把手。
  if (ball_snapped_) {
    ball_collapse_timer_ =
        SetTimer(ball_window_, kBallCollapseTimerId, 3000, nullptr);
  }
}

void FlutterWindow::DestroyBallWindow() {
  if (ball_window_ == nullptr) return;
  StopBallAnims();
  KillTimer(ball_window_, kBallTopTimerId);
  KillTimer(ball_window_, kBallDimTimerId);
  KillTimer(ball_window_, kBallIdleTimerId);
  ball_top_timer_ = 0;
  ball_dim_timer_ = 0;
  ball_idle_timer_ = 0;
  ball_dim_ = 1.0f;
  ball_dim_from_ = 1.0f;
  ball_dim_to_ = 1.0f;
  ball_hidden_by_fullscreen_ = false;
  DestroyWindow(ball_window_);
  ball_window_ = nullptr;
  ball_expanded_ = false;
  ball_snapped_ = false;
  ball_hover_tracked_ = false;
  ball_t_ = 0.0f;
  ball_peek_ = 0.0f;
}

void FlutterWindow::StopBallAnims() {
  if (ball_window_ == nullptr) return;
  KillTimer(ball_window_, kBallAnimTimerId);
  KillTimer(ball_window_, kBallHoverTimerId);
  KillTimer(ball_window_, kBallCollapseTimerId);
  KillTimer(ball_window_, kBallLeaveTimerId);
  KillTimer(ball_window_, kBallSnapTimerId);
  ball_anim_timer_ = 0;
  ball_hover_timer_ = 0;
  ball_collapse_timer_ = 0;
  ball_leave_timer_ = 0;
  ball_snap_timer_ = 0;
  ball_anim_kind_ = 0;
}

RECT FlutterWindow::BallWorkArea() const {
  // 用球所在那台显示器的工作区：SPI_GETWORKAREA 只给主屏，
  // 球拖到副屏时会被夹回主屏边缘，也就谈不上"贴着屏幕边"。
  HMONITOR mon = ball_window_ != nullptr
                     ? MonitorFromWindow(ball_window_, MONITOR_DEFAULTTONEAREST)
                     : nullptr;
  MONITORINFO mi{sizeof(MONITORINFO)};
  if (mon != nullptr && GetMonitorInfoW(mon, &mi)) return mi.rcWork;
  RECT work;
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  return work;
}

// 展开成完整球体。
void FlutterWindow::ExpandBall(bool animate) {
  if (ball_window_ == nullptr) return;
  KillTimer(ball_window_, kBallLeaveTimerId);
  ball_leave_timer_ = 0;
  KillTimer(ball_window_, kBallCollapseTimerId);
  ball_collapse_timer_ = 0;
  // 注意这里**不清** ball_peek_：此刻把手正被悬停放大着，
  // 直接归零会让它在展开的第一帧"啪"地瘦回去。渲染时按 handle_p 加权，
  // 它会随着把手一起退场（见 RenderBall）。
  if (animate && ball_anim_kind_ == 0) {
    ball_expanded_ = true;
    StartBallAnim(kBallAnimExpand);
  } else {
    StopBallAnims();
    ball_expanded_ = true;
    RenderBall(1, 255, 1.0f);
    if (ball_snapped_) {
      ball_collapse_timer_ = SetTimer(ball_window_, kBallCollapseTimerId, 3000,
                                      nullptr);
    }
  }
}

// 缩回边缘把手。
void FlutterWindow::CollapseBall() {
  if (ball_window_ == nullptr) return;
  KillTimer(ball_window_, kBallLeaveTimerId);
  ball_leave_timer_ = 0;
  ball_peek_ = 0.0f;
  if (ball_anim_kind_ == 0) {
    ball_expanded_ = false;
    StartBallAnim(kBallAnimCollapse);
  }
}

// 有新传输请求时：展开并播放提示动画。
void FlutterWindow::ShowBallAlert() {
  if (ball_window_ == nullptr) return;
  StopBallAnims();
  // 要提示就得看得见：半透明的球先立刻恢复不透明。
  NoteBallActivity();
  ball_expanded_ = true;
  StartBallAnim(kBallAnimAlert);
  ShowWindow(ball_window_, SW_SHOWNOACTIVATE);
}

// 启动一段球动画。kind 决定终点，起点一律取"当前形态"——
// 动画中途被打断（悬停展开时来了新请求、拖到一半又缩回）也能从当前帧接着走，
// 不会跳回起点重播。
void FlutterWindow::StartBallAnim(int kind) {
  if (ball_window_ == nullptr) return;
  KillTimer(ball_window_, kBallAnimTimerId);
  ball_anim_kind_ = kind;
  ball_anim_start_ = GetTickCount64();
  switch (kind) {
    case kBallAnimExpand:
      ball_anim_from_ = ball_t_;
      ball_anim_duration_ = kBallExpandMs;
      break;
    case kBallAnimCollapse:
      ball_anim_from_ = ball_t_;
      ball_anim_duration_ = kBallCollapseMs;
      break;
    case kBallAnimAlert:
      ball_anim_from_ = ball_t_;
      ball_anim_duration_ = kBallAlertMs;
      break;
    case kBallAnimPeekIn:
    case kBallAnimPeekOut:
      ball_anim_from_ = ball_peek_;
      ball_anim_duration_ = kBallPeekMs;
      break;
    default:
      ball_anim_from_ = ball_t_;
      ball_anim_duration_ = 200;
      break;
  }
  ball_anim_timer_ = SetTimer(ball_window_, kBallAnimTimerId, 16, nullptr);
  // 立刻画一帧：别让第一帧空等一个定时器周期。
  StepBallAnim();
}

// 推进一帧球动画。
void FlutterWindow::StepBallAnim() {
  if (ball_window_ == nullptr || ball_anim_kind_ == 0) return;
  const ULONGLONG now = GetTickCount64();
  const float p = ball_anim_duration_ > 0
                      ? Clamp01((now - ball_anim_start_) /
                                static_cast<float>(ball_anim_duration_))
                      : 1.0f;
  const int kind = ball_anim_kind_;
  switch (kind) {
    case kBallAnimExpand:
      // 把手退回 + 球长出来，两者共用同一个 t，中间是连续的过渡形态。
      // t 直接跟时间线性走：缓动全交给 RenderBall 里的 S 曲线去做。
      // 在这里再叠一层 ease-out/ease-in-out，尺寸就会在动画前 1/3 跑满，
      // 剩下的时间看着像"卡住了"。
      RenderBall(ball_anim_from_ + (1.0f - ball_anim_from_) * p, 255, 1.0f);
      break;
    case kBallAnimCollapse:
      RenderBall(ball_anim_from_ * (1.0f - p), 255, 1.0f);
      break;
    case kBallAnimPeekIn:
      ball_peek_ = ball_anim_from_ + (1.0f - ball_anim_from_) * EaseOutCubic(p);
      RenderBall(ball_t_, 255, 1.0f);
      break;
    case kBallAnimPeekOut:
      ball_peek_ = ball_anim_from_ * (1.0f - EaseInOutCubic(p));
      RenderBall(ball_t_, 255, 1.0f);
      break;
    case kBallAnimAlert: {
      // 先长出来（若已经是球体就跳过），再呼吸两下。
      // 结束后保持展开，等 Dart 在流程结束点明确调 collapseBall。
      const ULONGLONG elapsed = now - ball_anim_start_;
      if (elapsed < kBallAlertMs / 5 && ball_anim_from_ < 1.0f) {
        const float grow = EaseOutCubic(elapsed / (kBallAlertMs / 5.0f));
        RenderBall(ball_anim_from_ + (1.0f - ball_anim_from_) * grow, 255, 1.0f);
        break;
      }
      const float rest = static_cast<float>(kBallAlertMs) - kBallAlertMs / 5.0f;
      const float e = rest > 0 ? Clamp01((elapsed - kBallAlertMs / 5.0f) / rest)
                               : 1.0f;
      // 两次呼吸：尺寸和透明度反向起伏（变大时略淡），比"闪两下"柔和。
      const float k = 0.5f - 0.5f * cosf(e * 6.2831853f * 2.0f);
      RenderBall(1.0f, static_cast<BYTE>(255 - 40 * k), 1.0f + 0.05f * k);
      break;
    }
    default:
      break;
  }
  if (p < 1.0f) return;

  KillTimer(ball_window_, kBallAnimTimerId);
  ball_anim_timer_ = 0;
  ball_anim_kind_ = 0;
  switch (kind) {
    case kBallAnimExpand:
      RenderBall(1.0f, 255, 1.0f);
      if (ball_snapped_) {
        // 展开后鼠标若不在球上，几秒后自动缩回。
        KillTimer(ball_window_, kBallCollapseTimerId);
        ball_collapse_timer_ =
            SetTimer(ball_window_, kBallCollapseTimerId, 3000, nullptr);
      }
      break;
    case kBallAnimCollapse:
      RenderBall(0.0f, 255, 1.0f);
      break;
    case kBallAnimPeekIn:
      ball_peek_ = 1.0f;
      RenderBall(ball_t_, 255, 1.0f);
      break;
    case kBallAnimPeekOut:
      ball_peek_ = 0.0f;
      RenderBall(ball_t_, 255, 1.0f);
      break;
    default:
      RenderBall(1.0f, 255, 1.0f);
      break;
  }
}

// 拖动结束后吸附到最近的屏幕边缘，并安排缩回把手。
void FlutterWindow::SnapBallToEdge() {
  if (ball_window_ == nullptr) return;
  RECT wr;
  GetWindowRect(ball_window_, &wr);
  int size = wr.right - wr.left;

  RECT work = BallWorkArea();
  int margin = ScaleFor(ball_window_, kSnapMargin);
  ball_snapped_ = true;

  // 判断最近的边（两边都不近则不吸附，保持自由位置）。
  int dl = wr.left - work.left;
  int dr = work.right - wr.right;
  int dt = wr.top - work.top;
  int db = work.bottom - wr.bottom;
  int best = dl;
  int edge = 0;  // left
  if (dr < best) { best = dr; edge = 1; }
  if (dt < best) { best = dt; edge = 2; }
  if (db < best) { best = db; edge = 3; }
  if (best > margin) {
    ball_snapped_ = false;
    ball_edge_ = -1;
    ball_free_pos_ = POINT{wr.left, wr.top};
    ExpandBall(false);
    // 通知 Dart 记忆自由位置。
    InvokeDart("onBallPosition",
               flutter::EncodableMap{
                   {"x", flutter::EncodableValue(wr.left)},
                   {"y", flutter::EncodableValue(wr.top)},
                   {"snapped", flutter::EncodableValue(false)},
                   {"edge", flutter::EncodableValue(-1)},
               });
    return;
  }
  ball_edge_ = edge;

  // 把手要**贴着**屏幕边缘：窗口直接顶到工作区边界，留白交给 RenderBall 里
  // 的溢出裁剪处理（把手那一侧画到窗口外，由窗口边界切平）。
  // 以前这里留了 kHandleOutset 的 inset，屏幕上就空出 6pt，看着没贴住。
  const int inset = 0;
  int x;
  int y;
  switch (edge) {
    case 0:  // left
      x = work.left + inset;
      y = wr.top;
      break;
    case 1:  // right
      x = work.right - size - inset;
      y = wr.top;
      break;
    case 2:  // top
      x = wr.left;
      y = work.top + inset;
      break;
    default:  // bottom
      x = wr.left;
      y = work.bottom - size - inset;
      break;
  }
  // 沿边方向夹回工作区内。
  if (edge == 0 || edge == 1) {
    if (y < work.top) y = work.top;
    if (y + size > work.bottom) y = work.bottom - size;
  } else {
    if (x < work.left) x = work.left;
    if (x + size > work.right) x = work.right - size;
  }
  // 滑到边缘（不再瞬移）：拖动松手的位置往往离边缘还有几十像素，
  // 直接 SetWindowPos 会让球"跳"过去，跟手的拖拽感断掉。
  RECT cur;
  GetWindowRect(ball_window_, &cur);
  if (cur.left != x || cur.top != y) {
    ball_snap_from_ = POINT{cur.left, cur.top};
    ball_snap_to_ = POINT{x, y};
    ball_snap_start_ = GetTickCount64();
    const int dist = std::max(abs(x - cur.left), abs(y - cur.top));
    // 140ms 起步，远距离最多再补 120ms，避免"长距离慢慢蹭"。
    ball_snap_duration_ = 140 + std::min(120, dist);
    KillTimer(ball_window_, kBallSnapTimerId);
    ball_snap_timer_ = SetTimer(ball_window_, kBallSnapTimerId, 16, nullptr);
    StepBallSnap();
  } else {
    // 已经贴边：直接进入"停一下再缩回"。
    KillTimer(ball_window_, kBallCollapseTimerId);
    ball_collapse_timer_ = SetTimer(ball_window_, kBallCollapseTimerId, 420,
                                    nullptr);
  }

  // 通知 Dart 记忆吸附位置。
  InvokeDart("onBallPosition",
             flutter::EncodableMap{
                 {"x", flutter::EncodableValue(x)},
                 {"y", flutter::EncodableValue(y)},
                 {"snapped", flutter::EncodableValue(true)},
                 {"edge", flutter::EncodableValue(edge)},
             });
}

// 吸附滑行的一帧。
void FlutterWindow::StepBallSnap() {
  if (ball_window_ == nullptr) return;
  const float p =
      ball_snap_duration_ > 0
          ? Clamp01((GetTickCount64() - ball_snap_start_) /
                    static_cast<float>(ball_snap_duration_))
          : 1.0f;
  const float e = EaseOutCubic(p);
  const int x = ball_snap_from_.x +
                static_cast<int>((ball_snap_to_.x - ball_snap_from_.x) * e);
  const int y = ball_snap_from_.y +
                static_cast<int>((ball_snap_to_.y - ball_snap_from_.y) * e);
  SetWindowPos(ball_window_, nullptr, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  if (p < 1.0f) return;
  KillTimer(ball_window_, kBallSnapTimerId);
  ball_snap_timer_ = 0;
  SetWindowPos(ball_window_, nullptr, ball_snap_to_.x, ball_snap_to_.y, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  // 滑到位后再停一下缩回把手：两段动画首尾相接，不是同时抢戏。
  KillTimer(ball_window_, kBallCollapseTimerId);
  ball_collapse_timer_ =
      SetTimer(ball_window_, kBallCollapseTimerId, 420, nullptr);
}

// ---------------------------------------------------------------------------
// 空闲变暗 + 置顶守护
// ---------------------------------------------------------------------------

// 光标在球上（或正在拖动、正在提示）：取消空闲计时，并立刻回到不透明。
//
// 只在"当前确实偏暗"时才启动恢复动画。WM_MOUSEMOVE 是连续来的，
// 每次都重启一遍动画会让它永远停在半路——那才是真正的"闪烁"来源。
void FlutterWindow::NoteBallActivity() {
  if (ball_window_ == nullptr) return;
  if (ball_idle_timer_ != 0) {
    KillTimer(ball_window_, kBallIdleTimerId);
    ball_idle_timer_ = 0;
  }
  if (ball_dim_ < 0.999f || ball_dim_to_ < 0.999f) StartBallDim(false);
}

// 光标离开：1s 后才开始变暗。留这 1s 是因为鼠标常常只是路过，
// 一走开就淡掉会让人以为控件没了。
void FlutterWindow::ScheduleBallIdle() {
  if (ball_window_ == nullptr) return;
  if (ball_idle_timer_ != 0) return;  // 已经在排队了，别续期
  ball_idle_timer_ = SetTimer(ball_window_, kBallIdleTimerId, kBallIdleDelayMs,
                              nullptr);
}

void FlutterWindow::StartBallDim(bool dim) {
  if (ball_window_ == nullptr) return;
  const float target = dim ? kBallDimAlpha : 1.0f;
  // 已经在朝同一个目标走：直接返回。重启会让动画回到起点，看着像卡住。
  if (ball_dim_timer_ != 0 && std::abs(ball_dim_to_ - target) < 0.001f) return;
  if (ball_dim_timer_ == 0 && std::abs(ball_dim_ - target) < 0.001f) return;

  ball_dim_from_ = ball_dim_;
  ball_dim_to_ = target;
  ball_dim_start_ = GetTickCount64();
  ball_dim_duration_ = dim ? kBallDimMs : kBallUndimMs;
  if (ball_dim_timer_ == 0) {
    ball_dim_timer_ = SetTimer(ball_window_, kBallDimTimerId, 16, nullptr);
  }
  StepBallDim();
}

void FlutterWindow::StepBallDim() {
  if (ball_window_ == nullptr) return;
  const float p =
      ball_dim_duration_ > 0
          ? Clamp01((GetTickCount64() - ball_dim_start_) /
                    static_cast<float>(ball_dim_duration_))
          : 1.0f;
  // 变暗用 ease-in-out（慢慢淡下去），恢复用 ease-out（一下子精神起来）。
  const float e = ball_dim_to_ < ball_dim_from_ ? EaseInOutCubic(p)
                                               : EaseOutCubic(p);
  ball_dim_ = ball_dim_from_ + (ball_dim_to_ - ball_dim_from_) * e;
  if (p >= 1.0f) {
    KillTimer(ball_window_, kBallDimTimerId);
    ball_dim_timer_ = 0;
    ball_dim_ = ball_dim_to_;
  }
  RenderBall(ball_t_, ball_alpha_, ball_scale_);
}

// 前台是不是全屏应用（游戏/视频/演示）。
//
// 判定要严格：必须盖住**整个显示器**（含任务栏区域），且不是桌面/任务栏自己。
// 只比工作区会把最大化窗口误判成全屏，那样球会在正常办公时莫名消失。
bool FlutterWindow::FullscreenAppForeground() {
  HWND fg = GetForegroundWindow();
  if (fg == nullptr) return false;
  if (fg == ball_window_ || fg == GetHandle()) return false;
  if (!IsWindowVisible(fg) || IsIconic(fg)) return false;

  wchar_t cls[64] = {0};
  GetClassNameW(fg, cls, 64);
  if (lstrcmpW(cls, L"Progman") == 0 || lstrcmpW(cls, L"WorkerW") == 0 ||
      lstrcmpW(cls, L"Shell_TrayWnd") == 0 ||
      lstrcmpW(cls, L"Shell_SecondaryTrayWnd") == 0) {
    return false;
  }

  RECT r;
  if (!GetWindowRect(fg, &r)) return false;
  HMONITOR mon = MonitorFromWindow(fg, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{sizeof(MONITORINFO)};
  if (mon == nullptr || !GetMonitorInfoW(mon, &mi)) return false;
  return r.left <= mi.rcMonitor.left && r.top <= mi.rcMonitor.top &&
         r.right >= mi.rcMonitor.right && r.bottom >= mi.rcMonitor.bottom;
}

// 每 600ms 跑一次：全屏应用在用时把球藏起来，否则重申置顶。
//
// 只在前台窗口**变了**的时候才调 SetWindowPos：分层窗口每次重新合成都可能
// 闪一下，定时无脑重申置顶反而会让把手一闪一闪。
void FlutterWindow::UpdateBallTopmost() {
  if (ball_window_ == nullptr) return;
  const bool fullscreen = FullscreenAppForeground();

  if (fullscreen) {
    if (!ball_hidden_by_fullscreen_) {
      ball_hidden_by_fullscreen_ = true;
      ShowWindow(ball_window_, SW_HIDE);
    }
    return;
  }

  if (ball_hidden_by_fullscreen_) {
    ball_hidden_by_fullscreen_ = false;
    ShowWindow(ball_window_, SW_SHOWNOACTIVATE);
    SetWindowPos(ball_window_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    RenderBall(ball_t_, ball_alpha_, ball_scale_);
    ball_last_foreground_ = GetForegroundWindow();
    return;
  }

  const HWND fg = GetForegroundWindow();
  if (fg != ball_last_foreground_) {
    ball_last_foreground_ = fg;
    SetWindowPos(ball_window_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
}

// 渲染悬浮球。t: 0=把手 1=完整球；alpha 全局不透明度；scale 呼吸缩放。
//
// 这里**不再用 ball.png**。贴图里烤了一圈硬边阴影，缩到 55px 时会被读成
// "白盘外面还有一道灰边"，也就是用户反复报的"双边框"。而且贴图没法做形状
// 形变，只能靠"把手淡出 + 球淡入"交叉过渡，看着像两个东西换了岗。
//
// 现在整块图形只有一个形状：一个圆角矩形的宽/高/圆角同时从"药丸"插值到
// "圆"，中途用阻尼弹簧过冲一下。青色核心从"整个把手"缩成图标里那张卡，
// 白色底盘在它周围长出来——读起来就是把手自己胀成了球，而不是换了个东西。
void FlutterWindow::RenderBall(float t, BYTE alpha, float scale) {
  if (ball_window_ == nullptr) return;
  ball_t_ = Clamp01(t);
  t = ball_t_;
  HWND hwnd = ball_window_;
  const int size = ScaleFor(hwnd, kBallWindow);

  LayeredCanvas canvas;
  if (!canvas.Begin(hwnd, size, size)) return;
  Gdiplus::Graphics& g = *canvas.graphics();

  // 记住这次的整体参数：空闲变暗要按原样重画，不能把提示态的 alpha 冲掉。
  ball_alpha_ = alpha;
  ball_scale_ = scale;
  const float op = (alpha / 255.0f) * ball_dim_;  // 0..1

  // ---- 形态进度 ----
  // s 带过冲（峰值约 1.07），sc 夹回 0..1 只给"锚点"这类不能越界的量用。
  const float s = Spring01(t);
  const float sc = Clamp01(s);

  const float hs = static_cast<float>(ScaleFor(hwnd, kHandleSize));
  const float hl = static_cast<float>(ScaleFor(hwnd, kHandleLength));
  const float pill_thick = hs * 1.1f;  // 把手可见厚度
  const float pill_len = hl;           // 把手可见长度
  const float disc =
      size * (kBallWindow - 2.0f * kHandleOutset) / kBallWindow * scale;

  // 悬停反馈：光标一到位把手先胖一点，权重乘把手占比，展开时自动淡出。
  const float peek = ball_peek_ * (1.0f - sc);
  // 过冲时把"沿边方向"压一点：体积守恒的果冻感，比单纯放大更像有弹性。
  const float jelly = 1.0f - 0.30f * (s - 1.0f);
  const float across = (pill_thick + (disc - pill_thick) * s) * (1.0f + 0.26f * peek);
  const float along =
      (pill_len + (disc - pill_len) * s) * jelly * (1.0f + 0.04f * peek);
  const float radius = across * 0.5f;  // 圆角恒取厚度一半 → 药丸/正圆

  const float c = size / 2.0f;
  const float inset = (size - disc) * 0.5f;
  // 贴边侧的锚点：把手贴在窗口边上（窗口本身已经贴屏幕边），球体退进 inset。
  const float anchor = inset * sc;
  // 把手那一侧的圆角要溢出窗口被裁掉，否则露出两个圆角缺口、看着没贴住。
  const float ext = (1.0f - sc) * static_cast<float>(ScaleFor(hwnd, kHandleOutset));

  const bool vertical_edge = ball_edge_ <= 1;
  const float w = vertical_edge ? across : along;
  const float h = vertical_edge ? along : across;

  // shape 含溢出部分（会被窗口边界裁掉）；vis 是真正可见的那块。
  Gdiplus::RectF shape;
  Gdiplus::RectF vis;
  if (!ball_snapped_) {
    shape = Gdiplus::RectF(c - w / 2, c - h / 2, w, h);
    vis = shape;
  } else if (ball_edge_ == 0) {  // 左
    shape = Gdiplus::RectF(anchor - ext, c - h / 2, w + ext, h);
    vis = Gdiplus::RectF(anchor, c - h / 2, w, h);
  } else if (ball_edge_ == 1) {  // 右
    shape = Gdiplus::RectF(size - anchor - w, c - h / 2, w + ext, h);
    vis = Gdiplus::RectF(size - anchor - w, c - h / 2, w, h);
  } else if (ball_edge_ == 2) {  // 上
    shape = Gdiplus::RectF(c - w / 2, anchor - ext, w, h + ext);
    vis = Gdiplus::RectF(c - w / 2, anchor, w, h);
  } else {  // 下
    shape = Gdiplus::RectF(c - w / 2, size - anchor - h, w, h + ext);
    vis = Gdiplus::RectF(c - w / 2, size - anchor - h, w, h);
  }

  const Gdiplus::RectF discRect(c - disc / 2, c - disc / 2, disc, disc);

  // ---- 1. 白色底盘 + 柔和投影 ----
  // 投影用多层同心低 alpha 叠出渐变边，而不是一圈硬边——
  // 硬边阴影正是"双边框"的来源。
  const float plate_p = SmoothStep01(s / 0.20f);
  if (plate_p > 0.004f) {
    for (int i = 5; i >= 1; --i) {
      const float grow = i * 1.7f;
      const Gdiplus::RectF r(shape.X - grow, shape.Y - grow,
                             shape.Width + grow * 2, shape.Height + grow * 2);
      const int a = static_cast<int>(5.0f * plate_p * op * (1.0f - 0.13f * i));
      if (a > 0) FillRound(g, r, radius + grow, RGB(20, 46, 52), a);
    }
    FillRound(g, shape, radius, RGB(253, 252, 249),
              static_cast<int>(255 * plate_p * op));
  }

  // 图标装饰：背后那张浅青描边卡 + 前面那张青卡 + 两条白线 + 珊瑚点。
  // 全部按底盘直径的比例定位，和 ball.png 里的构图对齐。
  const float deco_p = SmoothStep01((s - 0.60f) / 0.30f);
  if (deco_p > 0.004f) {
    const Gdiplus::RectF back(discRect.X + disc * 0.315f,
                              discRect.Y + disc * 0.275f, disc * 0.345f,
                              disc * 0.345f);
    Gdiplus::GraphicsPath* p = RoundedRect(back, disc * 0.075f);
    Gdiplus::Pen pen(Gdiplus::Color(static_cast<BYTE>(150 * deco_p * op),
                                    GetRValue(kBrand), GetGValue(kBrand),
                                    GetBValue(kBrand)),
                     disc * 0.012f);
    g.DrawPath(&pen, p);
    delete p;
  }

  // ---- 2. 青色核心：整个把手 → 图标里的那张卡 ----
  const float core_p = Clamp01((s - 0.05f) / 0.85f);
  const Gdiplus::RectF icon(discRect.X + disc * 0.295f,
                            discRect.Y + disc * 0.342f, disc * 0.332f,
                            disc * 0.332f);
  const float icon_r = disc * 0.075f;
  const Gdiplus::RectF core(
      shape.X + (icon.X - shape.X) * core_p,
      shape.Y + (icon.Y - shape.Y) * core_p,
      shape.Width + (icon.Width - shape.Width) * core_p,
      shape.Height + (icon.Height - shape.Height) * core_p);
  const float core_r = radius + (icon_r - radius) * core_p;
  // 颜色也从把手的深青过渡到图标卡的亮青，收尾处和 App 图标一致。
  const int cr = static_cast<int>(GetRValue(kBrand) + (47 - GetRValue(kBrand)) * core_p);
  const int cg = static_cast<int>(GetGValue(kBrand) + (182 - GetGValue(kBrand)) * core_p);
  const int cb = static_cast<int>(GetBValue(kBrand) + (187 - GetBValue(kBrand)) * core_p);
  FillRound(g, core, core_r, RGB(cr, cg, cb), static_cast<int>(255 * op));

  // ---- 3. 白色细节：把手上的两个点 → 图标里的两条线 ----
  // 同一个元素连续变形，不是"点淡出、线淡入"。
  const float mark_p = core_p;
  const float dot_d = hs * 0.44f;
  for (int i = 0; i < 2; ++i) {
    const float sgn = i == 0 ? -1.0f : 1.0f;
    float x0;
    float y0;
    if (vertical_edge) {
      x0 = vis.X + vis.Width / 2;
      y0 = vis.Y + vis.Height / 2 + sgn * hl * 0.18f;
    } else {
      x0 = vis.X + vis.Width / 2 + sgn * hl * 0.18f;
      y0 = vis.Y + vis.Height / 2;
    }
    const float x1 = discRect.X + disc * (i == 0 ? 0.4675f : 0.4650f);
    const float y1 = discRect.Y + disc * (i == 0 ? 0.5620f : 0.6220f);
    const float w1 = disc * (i == 0 ? 0.225f : 0.160f);
    const float h1 = disc * 0.028f;

    const float cx = x0 + (x1 - x0) * mark_p;
    const float cy = y0 + (y1 - y0) * mark_p;
    const float mw = dot_d + (w1 - dot_d) * mark_p;
    const float mh = dot_d + (h1 - dot_d) * mark_p;
    FillRound(g, Gdiplus::RectF(cx - mw / 2, cy - mh / 2, mw, mh),
              (mw < mh ? mw : mh) * 0.5f, RGB(255, 255, 255),
              static_cast<int>(255 * op));
  }

  // ---- 4. 珊瑚点 ----
  const float dot_p = SmoothStep01((s - 0.66f) / 0.26f);
  if (dot_p > 0.004f) {
    const float dd = disc * 0.062f;
    Gdiplus::SolidBrush brush(
        Gdiplus::Color(static_cast<BYTE>(255 * dot_p * op), GetRValue(kAccent),
                       GetGValue(kAccent), GetBValue(kAccent)));
    g.FillEllipse(&brush, discRect.X + disc * 0.600f - dd / 2,
                  discRect.Y + disc * 0.390f - dd / 2, dd, dd);
  }

  canvas.Present(hwnd, nullptr);
}

// ---------------------------------------------------------------------------
// 打开外部链接
// ---------------------------------------------------------------------------

int FlutterWindow::OpenUrl(const std::wstring& url) {
  if (url.empty()) return -1;

  // 只放行 http/https：ShellExecute 能执行 exe 和打开本地文件，
  // 让 URL 参数进来就等于开了个任意执行的口子。
  std::wstring lowered = url;
  std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                  [](wchar_t c) { return static_cast<wchar_t>(::towlower(c)); });
  if (lowered.rfind(L"http://", 0) != 0 && lowered.rfind(L"https://", 0) != 0) {
    WispDbgLog("OpenUrl rejected non-http scheme");
    return -1;
  }

  // ShellExecuteW 是系统官方的「用默认程序打开」入口：它自己会找
  // http/https 的默认关联程序并把它拉起来。用 explorer.exe 转交是不行的——
  // 从 Flutter 起的子进程没有正确的交互式桌面关联，explorer.exe 收下 URL
  // 却不会真的打开浏览器，用户点了「下载最新版」就没反应了。
  HINSTANCE result = ShellExecuteW(GetHandle(), L"open", url.c_str(), nullptr,
                                   nullptr, SW_SHOWNORMAL);
  int code = static_cast<int>(reinterpret_cast<intptr_t>(result));
  WispDbgLog("OpenUrl ShellExecuteW code=" + std::to_string(code));
  // ShellExecute 成功返回 > 32；失败返回具体错误码（<= 32）。
  return code > 32 ? 0 : code;
}

// 启动本地安装程序（自动更新）。与 OpenUrl 一样是 ShellExecuteW，
// 但语义不同必须分开：安装器要提权（PrivilegesRequired=admin），
// 动词必须用 "runas" 才会正常弹 UAC；CreateProcess 直接启动带
// admin 清单的 exe 会报 ERROR_ELEVATION_REQUIRED。
//
// 只放行 .exe：openUrl 的教训同样适用——这个通道一旦能开任意路径，
// 就等于开了一个任意执行的口子。
bool FlutterWindow::RunInstaller(const std::wstring& path,
                                 const std::wstring& args) {
  if (path.size() < 4) return false;
  std::wstring lowered = path;
  std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(::towlower(c)); });
  if (lowered.rfind(L".exe") != lowered.size() - 4) {
    WispDbgLog("RunInstaller rejected non-exe path");
    return false;
  }
  DWORD attrs = GetFileAttributesW(path.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_DIRECTORY)) {
    WispDbgLog("RunInstaller: file not found");
    return false;
  }
  HINSTANCE result = ShellExecuteW(GetHandle(), L"runas", path.c_str(),
                                   args.empty() ? nullptr : args.c_str(),
                                   nullptr, SW_SHOWNORMAL);
  int code = static_cast<int>(reinterpret_cast<intptr_t>(result));
  WispDbgLog("RunInstaller ShellExecuteW code=" + std::to_string(code));
  return code > 32;
}

// ---------------------------------------------------------------------------
// 通知卡片（替代系统 toast；ask / progress / done 三态）
// ---------------------------------------------------------------------------

// 抓取窗口客户区在屏幕上的真实像素，统计平均亮度与"接近纯黑"的占比，
// 并可选存成 PNG 供人眼核对。
//
// 用来客观判定"主窗口是不是黑屏"、"通知卡是不是真的画出来了"——
// IsWindowVisible 只说明窗口显示了，不代表上面有像素。
// 从屏幕 DC 做 BitBlt（而不是 PrintWindow）：PrintWindow 走的是 WM_PRINT，
// Direct3D/Impeller 的窗口不会照着画，抓回来可能一片黑，误判。
bool CaptureWindowStats(HWND hwnd, double* mean_out, double* dark_out,
                         const std::wstring& png_path) {
  *mean_out = 0;
  *dark_out = 0;
  if (hwnd == nullptr || !IsWindowVisible(hwnd)) return false;

  RECT wr{};
  if (!GetWindowRect(hwnd, &wr)) return false;
  const int w = wr.right - wr.left;
  const int h = wr.bottom - wr.top;
  if (w <= 0 || h <= 0) return false;

  HDC screen = GetDC(nullptr);
  if (screen == nullptr) return false;
  HDC mem = CreateCompatibleDC(screen);
  HBITMAP bmp = mem != nullptr ? CreateCompatibleBitmap(screen, w, h) : nullptr;
  if (mem == nullptr || bmp == nullptr) {
    if (bmp != nullptr) DeleteObject(bmp);
    if (mem != nullptr) DeleteDC(mem);
    ReleaseDC(nullptr, screen);
    return false;
  }
  HGDIOBJ old = SelectObject(mem, bmp);
  BitBlt(mem, 0, 0, w, h, screen, wr.left, wr.top, SRCCOPY);

  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;  // top-down
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  std::vector<BYTE> pixels(static_cast<size_t>(w) * h * 4, 0);
  GetDIBits(mem, bmp, 0, h, pixels.data(), &bi, DIB_RGB_COLORS);

  SelectObject(mem, old);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);

  const size_t total = static_cast<size_t>(w) * h;
  double sum = 0;
  size_t dark = 0;
  for (size_t i = 0; i < total; i++) {
    const double lum = 0.299 * pixels[i * 4 + 0] + 0.587 * pixels[i * 4 + 1] +
                       0.114 * pixels[i * 4 + 2];
    sum += lum;
    if (lum < 12) dark++;
  }
  *mean_out = total > 0 ? sum / static_cast<double>(total) : 0;
  *dark_out = total > 0 ? static_cast<double>(dark) / static_cast<double>(total) : 0;

  // 顺带把抓到的像素存成 PNG，方便人眼确认到底画出来没有。
  if (!png_path.empty()) {
    static const CLSID kPngClsid = {
        0x557cf406, 0x1a04, 0x11d3,
        {0x9a, 0x73, 0x00, 0x00, 0xf8, 0x1e, 0xf3, 0x6e}};
    Gdiplus::Bitmap* image = Gdiplus::Bitmap::FromHBITMAP(bmp, nullptr);
    if (image != nullptr) {
      image->Save(png_path.c_str(), &kPngClsid, nullptr);
      delete image;
    }
  }
  DeleteObject(bmp);
  return true;
}

void FlutterWindow::ShowToast(const std::wstring& title,
                              const std::wstring& body, int mode,
                              const std::wstring& progress) {
  WispDbgLog("ShowToast mode=" + std::to_string(mode) + " hwnd_alive=" +
             std::to_string(toast_window_ != nullptr));
  if (toast_window_ == nullptr) {
    CreateToastWindow();
    if (toast_window_ == nullptr) {
      WispDbgLog("ShowToast: CreateToastWindow failed");
      return;
    }
  }
  toast_title_ = title;
  toast_body_ = body;
  toast_mode_ = mode;
  toast_progress_ = progress;

  // 位置：工作区右下角。锚点在这里算一次，之后每帧都相对它定位。
  RECT work = BallWorkArea();
  int w = ScaleFor(toast_window_, kCardWidth + kCardMargin * 2);
  int h = ScaleFor(toast_window_, kCardHeight + kCardMargin * 2);
  int margin = ScaleFor(toast_window_, 14);
  toast_anchor_.x = work.right - w - margin;
  toast_anchor_.y = work.bottom - h - margin;
  // 夹回工作区（多显示器/任务栏位置异常时兜底）。
  if (toast_anchor_.x < work.left) toast_anchor_.x = work.left;
  if (toast_anchor_.y < work.top) toast_anchor_.y = work.top;

  SetWindowPos(toast_window_, nullptr, toast_anchor_.x, toast_anchor_.y, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  ShowWindow(toast_window_, SW_SHOWNOACTIVATE);
  toast_active_ = true;
  toast_drawn_ = false;
  WispDbgLog("ShowToast: shown visible=" +
             std::to_string(IsWindowVisible(toast_window_) ? 1 : 0));
  // 存活时间按模式区分：询问 30s（用户要想一想）；进度 8s（每次更新顺延）；
  // 完成 8s；取消提示 3s（看完即走）。
  KillTimer(toast_window_, kToastTimeoutTimerId);
  toast_timeout_timer_ = SetTimer(toast_window_, kToastTimeoutTimerId,
                                  ToastLifetimeMs(mode), nullptr);
  // 入场动画：只做淡入，**位置不动**。
  //
  // 以前是"先画到屏幕外再滑进来"——只要动画帧没跑到（平台线程正忙、
  // 计时器被清掉），卡片就永远停在屏幕外，而 IsWindowVisible 仍报 true，
  // 用户看到的就是"第一次不出现、再来一次才出现"。
  // 改成位置固定、透明度从 0.6 淡到 1.0：动画丢帧最多让卡片淡一点，
  // 绝不会让它跑到屏幕外去。
  KillTimer(toast_window_, kToastAnimTimerId);
  toast_anim_start_ = GetTickCount64();
  RenderToast(kToastFadeStart);
  toast_anim_timer_ = SetTimer(toast_window_, kToastAnimTimerId, 16, nullptr);
}

void FlutterWindow::UpdateToast(const std::wstring& body, int mode,
                                const std::wstring& progress) {
  // 用显式的"活着"标志而不是 IsWindowVisible：后者在窗口刚被隐藏、
  // 或还没画完第一帧时都不准，会让更新被静默丢掉（进度条不动）。
  if (!toast_active_) return;
  toast_body_ = body;
  toast_mode_ = mode;
  toast_progress_ = progress;
  RenderToast(1.0f);
  // 有内容更新就顺延存活时间（进度每 200ms 一次，卡片保持到传输结束）。
  KillTimer(toast_window_, kToastTimeoutTimerId);
  toast_timeout_timer_ = SetTimer(toast_window_, kToastTimeoutTimerId,
                                  ToastLifetimeMs(mode), nullptr);
}

void FlutterWindow::HideToast() {
  if (toast_window_ == nullptr) return;
  WispDbgLog("HideToast mode=" + std::to_string(toast_mode_));
  KillTimer(toast_window_, kToastTimeoutTimerId);
  toast_timeout_timer_ = 0;
  KillTimer(toast_window_, kToastAnimTimerId);
  toast_anim_timer_ = 0;
  toast_active_ = false;
  toast_drawn_ = false;
  ShowWindow(toast_window_, SW_HIDE);
}

void FlutterWindow::CreateToastWindow() {
  HINSTANCE instance = GetModuleHandle(nullptr);

  WNDCLASSW wc{};
  wc.lpfnWndProc = ToastWndProc;
  wc.hInstance = instance;
  wc.lpszClassName = kToastClass;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClassW(&wc);

  int w = ScaleFor(GetHandle(), kCardWidth + kCardMargin * 2);
  int h = ScaleFor(GetHandle(), kCardHeight + kCardMargin * 2);
  toast_window_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kToastClass, L"", WS_POPUP, 0, 0, w, h, nullptr, nullptr, instance,
      nullptr);
}

void FlutterWindow::DestroyToastWindow() {
  if (toast_window_ == nullptr) return;
  KillTimer(toast_window_, kToastAnimTimerId);
  KillTimer(toast_window_, kToastTimeoutTimerId);
  toast_anim_timer_ = 0;
  toast_timeout_timer_ = 0;
  DestroyWindow(toast_window_);
  toast_window_ = nullptr;
}

// 通知卡片的统一绘制：桌面通知卡与悬浮球气泡共用这一份实现。
//
// 规则 7 要求三种通知（应用内弹层 / 桌面卡片 / 气泡）字体、内容、布局一致，
// 所以这里只允许有一处排版逻辑。返回按钮命中区（客户区坐标）。
ToastButtons DrawCardContent(Gdiplus::Graphics& g, HWND hwnd, int win_w,
                             int win_h, const std::wstring& title,
                             const std::wstring& body, int mode,
                             const std::wstring& progress) {
  const float dpi = DpiScaleOf(hwnd);
  const int margin = ScaleFor(hwnd, kCardMargin);

  Gdiplus::RectF card(margin, margin, win_w - margin * 2.0f,
                      win_h - margin * 2.0f);
  const float radius = ScaleFor(hwnd, 18);
  DrawCardShadow(g, card, radius, 5);
  FillRound(g, card, radius, kCardBg);

  // 迷你图标。
  const float icon_size = ScaleFor(hwnd, 44);
  Gdiplus::RectF icon(margin + ScaleFor(hwnd, 16), margin + ScaleFor(hwnd, 18),
                      icon_size, icon_size);
  DrawMiniIcon(g, icon);

  const float text_x = icon.X + icon_size + ScaleFor(hwnd, 14);
  const float text_w = card.X + card.Width - ScaleFor(hwnd, 16) - text_x;

  Gdiplus::RectF title_rc(text_x, margin + ScaleFor(hwnd, 16), text_w,
                          ScaleFor(hwnd, 24));
  DrawString(g, title, title_rc, 15.0f * dpi, true, kText);

  Gdiplus::RectF body_rc(text_x, margin + ScaleFor(hwnd, 44), text_w,
                         ScaleFor(hwnd, 42));
  DrawWrapped(g, body, body_rc, 12.5f * dpi, false, kSubText);

  const int button_h = ScaleFor(hwnd, 32);
  const int button_y =
      margin + ScaleFor(hwnd, kCardHeight) - button_h - ScaleFor(hwnd, 14);
  const int gap = ScaleFor(hwnd, 8);
  const int half = (static_cast<int>(text_w) - gap) / 2;

  ToastButtons buttons{};
  buttons.card = RECT{0, 0, win_w, win_h};

  if (mode == kCardModeCanceled) {
    // 取消/中断提示：只有标题和正文，不放按钮也不放进度条——
    // 这张卡 3 秒后自动收起，不需要任何交互。
    return buttons;
  }

  if (mode == kCardModeProgress) {
    // 进度模式：进度条 + 百分比（不画按钮，避免误点）。
    Gdiplus::RectF bar(text_x, button_y + ScaleFor(hwnd, 8), text_w,
                       ScaleFor(hwnd, 8));
    FillRound(g, bar, bar.Height / 2, kChipBg);
    double ratio = 0;
    const size_t pct = progress.find(L'%');
    if (pct != std::wstring::npos) {
      try {
        ratio = std::stod(progress.substr(0, pct)) / 100.0;
      } catch (...) {
        ratio = 0;
      }
    }
    if (ratio > 0.02) {
      Gdiplus::RectF fill(bar.X, bar.Y, bar.Width * ratio, bar.Height);
      FillRound(g, fill, fill.Height / 2, kBrand);
    }
    Gdiplus::RectF pct_rc(text_x, bar.Y + ScaleFor(hwnd, 12), text_w,
                          ScaleFor(hwnd, 18));
    DrawString(g, progress, pct_rc, 11.5f * dpi, false, kSubText,
               Gdiplus::StringAlignmentCenter);
    return buttons;
  }

  const bool done = mode == kCardModeDone;
  RECT primary{text_x + half + gap, button_y, text_x + half + gap + half,
               button_y + button_h};
  RECT secondary{text_x, button_y, text_x + half, button_y + button_h};
  Gdiplus::RectF primary_f(primary.left, primary.top, primary.right - primary.left,
                           primary.bottom - primary.top);
  Gdiplus::RectF secondary_f(secondary.left, secondary.top,
                             secondary.right - secondary.left,
                             secondary.bottom - secondary.top);
  DrawButton(g, primary_f, !done, done ? L"打开目录" : L"接收", 13.5f * dpi);
  DrawButton(g, secondary_f, false, done ? L"关闭" : L"忽略", 13.5f * dpi);
  buttons.primary = primary;
  buttons.secondary = secondary;
  return buttons;
}

// fade: 0..1 的整体不透明度。位置永远是锚点，只有透明度会变。
//
// 为什么不能拿位置做动画：以前是"先画到屏幕外再滑进来"，只要动画帧没跑到
// （平台线程忙、计时器被清掉），卡片就永远停在屏幕外，而 IsWindowVisible
// 仍报 true——用户看到的就是"第一次不出现、再来一次才出现"。
// 改成位置固定、只调透明度之后，动画丢帧最多让卡片淡一点，绝不会消失。
void FlutterWindow::RenderToast(float fade) {
  if (toast_window_ == nullptr) return;
  HWND hwnd = toast_window_;
  int win_w = ScaleFor(hwnd, kCardWidth + kCardMargin * 2);
  int win_h = ScaleFor(hwnd, kCardHeight + kCardMargin * 2);

  POINT dst{toast_anchor_.x, toast_anchor_.y};

  LayeredCanvas canvas;
  if (!canvas.Begin(hwnd, win_w, win_h)) return;
  g_toast_buttons = DrawCardContent(*canvas.graphics(), hwnd, win_w, win_h,
                                    toast_title_, toast_body_, toast_mode_,
                                    toast_progress_);
  if (fade < 1.0f) {
    canvas.ApplyAlpha(static_cast<BYTE>(255.0f * fade));
  }
  // 画成功才算"真的出来了"——Dart 侧据此确认，必要时重发。
  toast_drawn_ = canvas.Present(hwnd, &dst);
}

void FlutterWindow::HandleToastClick(POINT pt) {
  // 进度卡不可点；取消提示 3 秒自动收，也不可点。
  if (toast_mode_ == kCardModeProgress || toast_mode_ == kCardModeCanceled) {
    return;
  }
  const char* action = nullptr;
  if (PtInRect(&g_toast_buttons.primary, pt)) {
    action = toast_mode_ == kCardModeDone ? "openFolder" : "accept";
  } else if (PtInRect(&g_toast_buttons.secondary, pt)) {
    if (toast_mode_ == kCardModeDone) {
      HideToast();  // 完成卡的"关闭"只收卡片，不回传。
      return;
    }
    action = "dismiss";
  }
  if (action != nullptr) {
    HideToast();
    flutter::EncodableMap args{
        {flutter::EncodableValue("action"),
         flutter::EncodableValue(std::string(action))}};
    InvokeDart("onBubbleAction", args);
    return;
  }
  // 点卡片其它位置：收起通知，打开主窗口处理。
  HideToast();
  RestoreWindow();
  InvokeDart("onToastClicked", flutter::EncodableMap{});
}

// ---------------------------------------------------------------------------
// 气泡
// ---------------------------------------------------------------------------

void FlutterWindow::CreateBubbleWindow() {
  HINSTANCE instance = GetModuleHandle(nullptr);

  WNDCLASSW wc{};
  wc.lpfnWndProc = BubbleWndProc;
  wc.hInstance = instance;
  wc.lpszClassName = kBubbleClass;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClassW(&wc);

  int w = ScaleFor(GetHandle(), kCardWidth + kCardMargin * 2);
  int h = ScaleFor(GetHandle(), kCardHeight + kCardMargin * 2);
  bubble_window_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kBubbleClass, L"", WS_POPUP, 100, 100, w, h, nullptr, nullptr, instance,
      nullptr);
}

void FlutterWindow::DestroyBubbleWindow() {
  if (bubble_window_ == nullptr) return;
  KillTimer(bubble_window_, kBubbleTimeoutTimerId);
  KillTimer(bubble_window_, kBubbleAnimTimerId);
  bubble_timeout_timer_ = 0;
  bubble_anim_timer_ = 0;
  bubble_anim_kind_ = 0;
  DestroyWindow(bubble_window_);
  bubble_window_ = nullptr;
  bubble_active_ = false;
  bubble_drawn_ = false;
}

// 悬浮球"可见内容"的屏幕矩形（规则 6：气泡要贴球体或把手，而不是贴窗口）。
//
// 球窗口恒为 kBallWindow 见方，展开时球体居中占 ~86%，吸附缩成把手后
// 真正可见的只有贴着屏幕边缘的那根细药丸，其余全是透明像素。
RECT FlutterWindow::BallContentRect() const {
  RECT empty{0, 0, 0, 0};
  if (ball_window_ == nullptr || !IsWindowVisible(ball_window_)) return empty;
  RECT br;
  GetWindowRect(ball_window_, &br);
  const int size = br.right - br.left;

  if (ball_expanded_) {
    // 球体直径 = 窗口边长 × (kBallWindow - 2*kHandleOutset) / kBallWindow。
    const int visual =
        size * (kBallWindow - 2 * kHandleOutset) / kBallWindow;
    const int cx = br.left + size / 2;
    const int cy = br.top + size / 2;
    return RECT{cx - visual / 2, cy - visual / 2, cx + visual / 2,
                cy + visual / 2};
  }

  // 把手：与 RenderBall 的 vis 矩形保持一致（贴边侧顶到窗口边界，
  // 可见厚度是 pill_thick，不再包含溢出窗口被裁掉的那一截）。
  const float hs = static_cast<float>(ScaleFor(ball_window_, kHandleSize));
  const float hl = static_cast<float>(ScaleFor(ball_window_, kHandleLength));
  const float thick = hs * 1.1f;
  const float c = size / 2.0f;
  float left = 0;
  float top = 0;
  float w = 0;
  float h = 0;
  if (ball_edge_ == 0) {
    left = 0;
    top = c - hl / 2;
    w = thick;
    h = hl;
  } else if (ball_edge_ == 1) {
    left = size - thick;
    top = c - hl / 2;
    w = thick;
    h = hl;
  } else if (ball_edge_ == 2) {
    left = c - hl / 2;
    top = 0;
    w = hl;
    h = thick;
  } else {
    left = c - hl / 2;
    top = size - thick;
    w = hl;
    h = thick;
  }
  return RECT{br.left + static_cast<int>(left),
              br.top + static_cast<int>(top),
              br.left + static_cast<int>(left + w),
              br.top + static_cast<int>(top + h)};
}

void FlutterWindow::ShowBubble(const std::wstring& title,
                               const std::wstring& body, int mode,
                               const std::wstring& progress) {
  if (bubble_window_ == nullptr) {
    CreateBubbleWindow();
    if (bubble_window_ == nullptr) return;
  }
  bubble_title_ = title;
  bubble_body_ = body;
  bubble_mode_ = mode;
  bubble_progress_ = progress;

  const int w = ScaleFor(bubble_window_, kCardWidth + kCardMargin * 2);
  const int h = ScaleFor(bubble_window_, kCardHeight + kCardMargin * 2);
  const RECT work = BallWorkArea();
  const int gap = ScaleFor(bubble_window_, 12);
  int x;
  int y;

  const RECT ball = BallContentRect();
  if (ball.right > ball.left) {
    // 规则 6：优先放在"远离屏幕边缘"的一侧；放不下就翻到另一侧。
    // 吸附在左边缘 → 气泡在球右侧；右边缘 → 左侧；上/下边缘同理。
    int edge = ball_edge_;
    if (!ball_snapped_) {
      // 未吸附：按球离哪边更近来决定朝向，避免气泡出界。
      const int dl = ball.left - work.left;
      const int dr = work.right - ball.right;
      edge = dl < dr ? 0 : 1;
    }
    if (edge <= 1) {
      const bool to_right = edge == 0;
      x = to_right ? ball.right + gap : ball.left - w - gap;
      if (x + w > work.right) x = ball.left - w - gap;
      if (x < work.left) x = ball.right + gap;
      // 垂直方向与球居中对齐，再夹回工作区。
      y = (ball.top + ball.bottom) / 2 - h / 2;
    } else {
      const bool below = edge == 2;
      y = below ? ball.bottom + gap : ball.top - h - gap;
      if (y + h > work.bottom) y = ball.top - h - gap;
      if (y < work.top) y = ball.bottom + gap;
      x = (ball.left + ball.right) / 2 - w / 2;
    }
  } else {
    // 没有悬浮球：退化成右下角。
    x = work.right - w - ScaleFor(bubble_window_, 16);
    y = work.bottom - h - ScaleFor(bubble_window_, 16);
  }

  // 最终夹回工作区，任何情况下都不许越界。
  if (x + w > work.right) x = work.right - w;
  if (y + h > work.bottom) y = work.bottom - h;
  if (x < work.left) x = work.left;
  if (y < work.top) y = work.top;
  bubble_anchor_ = POINT{x, y};

  // 入场方向：从球那一侧滑出来，落点回正。偏移很小（12 逻辑像素），
  // 主要是让气泡"从球里冒出来"，而不是凭空出现在旁边。
  bubble_slide_dx_ = 0;
  bubble_slide_dy_ = 0;
  if (ball.right > ball.left) {
    const int ball_cx = (ball.left + ball.right) / 2;
    const int ball_cy = (ball.top + ball.bottom) / 2;
    const int dx = (x + w / 2) - ball_cx;
    const int dy = (y + h / 2) - ball_cy;
    const int slide = ScaleFor(bubble_window_, 12);
    if (abs(dx) >= abs(dy)) {
      bubble_slide_dx_ = dx > 0 ? -slide : slide;
    } else {
      bubble_slide_dy_ = dy > 0 ? -slide : slide;
    }
  }

  SetWindowPos(bubble_window_, nullptr, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  ShowWindow(bubble_window_, SW_SHOWNOACTIVATE);
  bubble_active_ = true;
  bubble_drawn_ = false;
  // 入场动画：淡入 + 从球的方向滑入（以前是"啪"地整张出现）。
  StartBubbleAnim(1);

  KillTimer(bubble_window_, kBubbleTimeoutTimerId);
  bubble_timeout_timer_ = SetTimer(bubble_window_, kBubbleTimeoutTimerId,
                                   ToastLifetimeMs(bubble_mode_), nullptr);
}

void FlutterWindow::UpdateBubble(const std::wstring& body, int mode,
                                 const std::wstring& progress) {
  // 和 UpdateToast 一样用显式的"活着"标志，别用 IsWindowVisible。
  if (!bubble_active_) return;
  bubble_body_ = body;
  bubble_mode_ = mode;
  bubble_progress_ = progress;
  // 用 RefreshBubble 而不是直接整张重画：入场动画进行中的话，
  // 按当前帧继续画，否则更新会把动画"顶"成完整不透明度，画面一跳一跳。
  RefreshBubble();
  // 每次更新都顺延存活时间，跟 UpdateToast 对齐：
  //  - 进度态每 200ms 刷一次，计时器被不断续期，气泡不会中途自己消失；
  //  - 切到取消提示时按 3s 重新计时，看完自动收起。
  // 以前这里不重置计时器，气泡沿用上一个模式的剩余时间：
  //  进度跑到 8s 就凭空消失，取消提示也不会按 3s 收。
  KillTimer(bubble_window_, kBubbleTimeoutTimerId);
  bubble_timeout_timer_ = SetTimer(bubble_window_, kBubbleTimeoutTimerId,
                                   ToastLifetimeMs(mode), nullptr);
}

void FlutterWindow::HideBubble(bool animate) {
  if (bubble_window_ == nullptr) return;
  KillTimer(bubble_window_, kBubbleTimeoutTimerId);
  bubble_timeout_timer_ = 0;
  // 立刻"下线"：后续的 updateBubble 不该再画到一张正在退场的卡上。
  const bool was_active = bubble_active_;
  bubble_active_ = false;
  bubble_drawn_ = false;
  if (!animate || !was_active || !IsWindowVisible(bubble_window_)) {
    // 本来就没显示：不用演退场，直接收掉。
    KillTimer(bubble_window_, kBubbleAnimTimerId);
    bubble_anim_timer_ = 0;
    bubble_anim_kind_ = 0;
    ShowWindow(bubble_window_, SW_HIDE);
    return;
  }
  // 退场也走一小段动画（淡出 + 滑回球的方向），然后才真正隐藏窗口。
  StartBubbleAnim(2);
}

void FlutterWindow::StartBubbleAnim(int kind) {
  if (bubble_window_ == nullptr) return;
  KillTimer(bubble_window_, kBubbleAnimTimerId);
  bubble_anim_kind_ = kind;
  bubble_anim_start_ = GetTickCount64();
  bubble_anim_duration_ = kind == 1 ? kBubbleInMs : kBubbleOutMs;
  bubble_anim_timer_ = SetTimer(bubble_window_, kBubbleAnimTimerId, 16, nullptr);
  StepBubbleAnim();
}

void FlutterWindow::StepBubbleAnim() {
  if (bubble_window_ == nullptr || bubble_anim_kind_ == 0) return;
  const float p = bubble_anim_duration_ > 0
                      ? Clamp01((GetTickCount64() - bubble_anim_start_) /
                                static_cast<float>(bubble_anim_duration_))
                      : 1.0f;
  RefreshBubble();
  if (p < 1.0f) return;

  KillTimer(bubble_window_, kBubbleAnimTimerId);
  bubble_anim_timer_ = 0;
  const bool was_out = bubble_anim_kind_ == 2;
  bubble_anim_kind_ = 0;
  if (was_out) {
    bubble_drawn_ = false;
    ShowWindow(bubble_window_, SW_HIDE);
  } else {
    RenderBubble();
  }
}

void FlutterWindow::RefreshBubble() {
  if (bubble_window_ == nullptr) return;
  if (bubble_anim_kind_ == 0) {
    RenderBubbleAt(1.0f, 0, 0);
    return;
  }
  const float p = bubble_anim_duration_ > 0
                      ? Clamp01((GetTickCount64() - bubble_anim_start_) /
                                static_cast<float>(bubble_anim_duration_))
                      : 1.0f;
  if (bubble_anim_kind_ == 1) {
    const float e = EaseOutCubic(p);
    // 起点不是 0：万一动画一帧都没跑，卡片也是"位置正确、只是淡一点"，
    // 不会出现"通知来了但看不见"。
    RenderBubbleAt(0.45f + 0.55f * e,
                   static_cast<int>(bubble_slide_dx_ * (1.0f - e)),
                   static_cast<int>(bubble_slide_dy_ * (1.0f - e)));
  } else {
    const float e = EaseInOutCubic(p);
    RenderBubbleAt(1.0f - 0.92f * e,
                   static_cast<int>(bubble_slide_dx_ * e),
                   static_cast<int>(bubble_slide_dy_ * e));
  }
}

void FlutterWindow::RenderBubble() { RenderBubbleAt(1.0f, 0, 0); }

void FlutterWindow::RenderBubbleAt(float fade, int dx, int dy) {
  if (bubble_window_ == nullptr) return;
  HWND hwnd = bubble_window_;
  int win_w = ScaleFor(hwnd, kCardWidth + kCardMargin * 2);
  int win_h = ScaleFor(hwnd, kCardHeight + kCardMargin * 2);

  LayeredCanvas canvas;
  if (!canvas.Begin(hwnd, win_w, win_h)) return;
  // 与桌面通知卡走同一个绘制函数：字号、行距、按钮、进度条完全一致（规则 7）。
  ToastButtons buttons = DrawCardContent(*canvas.graphics(), hwnd, win_w, win_h,
                                         bubble_title_, bubble_body_,
                                         bubble_mode_, bubble_progress_);
  g_bubble_buttons = BubbleButtons{};
  g_bubble_buttons.primary = buttons.primary;
  g_bubble_buttons.secondary = buttons.secondary;
  // 整张卡的不透明度：预乘 alpha 的位图必须 RGB 和 A 一起缩，见 ApplyAlpha。
  canvas.ApplyAlpha(static_cast<BYTE>(Clamp01(fade) * 255.0f + 0.5f));
  POINT dst{bubble_anchor_.x + dx, bubble_anchor_.y + dy};
  // 画成功才算"真的出来了"——Dart 侧据此确认，必要时重试。
  // 注意这里**不按 fade 判定**：Dart 弹完立刻查一次，入场动画还没走完时
  // 若报"没画出来"，它会再发一次 showBubble，把淡入从头重播一遍。
  bubble_drawn_ = canvas.Present(hwnd, &dst);
}

void FlutterWindow::HandleBubbleClick(POINT pt) {
  const char* action = nullptr;
  // 进度卡与取消提示都不可点（提示 3 秒自动收）。
  if (bubble_mode_ != kCardModeProgress && bubble_mode_ != kCardModeCanceled) {
    if (PtInRect(&g_bubble_buttons.primary, pt)) {
      action = bubble_mode_ == kCardModeDone ? "openFolder" : "accept";
    } else if (PtInRect(&g_bubble_buttons.secondary, pt)) {
      action = "dismiss";
    }
  }
  if (action == nullptr) return;

  HideBubble();
  flutter::EncodableMap args{
      {flutter::EncodableValue("action"),
       flutter::EncodableValue(std::string(action))}};
  InvokeDart("onBubbleAction", args);
}

// ---------------------------------------------------------------------------
// 通用
// ---------------------------------------------------------------------------

void FlutterWindow::InvokeDart(const std::string& method, flutter::EncodableMap args) {
  if (channel_ == nullptr) return;
  channel_->InvokeMethod(method,
                         std::make_unique<flutter::EncodableValue>(args));
}

void FlutterWindow::ForceMainWindowRepaint() {
  HWND handle = GetHandle();
  if (handle == nullptr) return;
  // 窗口不可见时不做重绘：对一张没人看的表面 ForceRedraw 没有意义，
  // 而且 WM_ACTIVATE 在窗口藏起来时照样会来（见下面那段注释），
  // 不判可见性就会在收托盘期间白跑一轮重绘。
  if (!IsWindowVisible(handle) || IsIconic(handle)) return;
  // 隐藏置顶的桌面浮层（通知卡/气泡）会让 DWM 把它们原先占的那块区域重新
  // 合成一遍，而 Flutter(Impeller) 的交换链在那块区域可能还是空帧——
  // 用户看到的就是"通知出现后再打开主窗口，主窗口变黑"。
  // 把主窗口重新提到顶层再落回原位，强制整块区域重绘。
  SetWindowPos(handle, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  SetWindowPos(handle, HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  if (flutter_controller_) {
    flutter_controller_->ForceRedraw();
  }
  RedrawWindow(handle, nullptr, nullptr,
               RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
}

// Impeller 的交换链重建是异步的：单次 ForceRedraw 常常落在"表面还没就绪"
// 的空窗里，黑帧就留在屏幕上了（以前的症状：主窗口变黑）。
// 所以这里不是重绘一次，而是按越来越大的间隔连着重绘若干次，覆盖整个
// 表面重建过程——这是"一次性根治"而不是"赌一次时机"。
void FlutterWindow::ScheduleRestoreRedraws() {
  HWND handle = GetHandle();
  if (handle == nullptr) return;
  // 同上：窗口没显示就没必要补绘。
  if (!IsWindowVisible(handle) || IsIconic(handle)) return;
  KillTimer(handle, kRestoreRedrawTimerId);
  restore_redraw_step_ = 0;
  restore_redraw_timer_ = SetTimer(handle, kRestoreRedrawTimerId, 60, nullptr);
}

void FlutterWindow::RunRestoreRedrawStep() {
  ForceMainWindowRepaint();
  restore_redraw_step_++;
  if (restore_redraw_step_ >= kRestoreRedrawSteps) {
    KillTimer(GetHandle(), kRestoreRedrawTimerId);
    restore_redraw_timer_ = 0;
    return;
  }
  // 间隔指数增长：60 / 120 / 240 / 480 / 960 ms。
  const UINT next = 60u << restore_redraw_step_;
  KillTimer(GetHandle(), kRestoreRedrawTimerId);
  restore_redraw_timer_ =
      SetTimer(GetHandle(), kRestoreRedrawTimerId, next, nullptr);
}

void FlutterWindow::RestoreWindow() {
  HWND handle = GetHandle();
  if (handle == nullptr) {
    return;
  }
  // 先把桌面浮层收干净，再把主窗口显示出来：用户已经回到主窗口，
  // 让一个置顶的分层窗口继续在它上面演退场动画没有意义。
  SetTrayFlashing(false);
  HideToast();
  HideBubble(/*animate=*/false);
  ShowWindow(handle, SW_RESTORE);
  BringWindowToTop(handle);
  SetForegroundWindow(handle);
  // 用户回到主窗口：桌面上的提醒全部退场，后续进度/完成也改由主窗口呈现，
  // Dart 侧收到 onWindowRestored 后会停止推进通知流程。
  // Impeller 从隐藏态恢复时交换链还停留在黑帧，必须强制重绘。
  // 这里不赌单次时机：连着重绘若干次，覆盖表面重建的整个过程。
  ForceMainWindowRepaint();
  ScheduleRestoreRedraws();
  InvokeDart("onWindowRestored", flutter::EncodableMap{});
}

void FlutterWindow::ShowTrayMenu() {
  POINT cursor;
  GetCursorPos(&cursor);

  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kTrayCommandShow, L"显示 Wisp");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayCommandQuit, L"退出");

  // TrackPopupMenu 需要窗口在前台，否则菜单闪一下就没了。
  SetForegroundWindow(GetHandle());
  UINT command = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD, cursor.x,
                                cursor.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);

  if (command == kTrayCommandShow) {
    RestoreWindow();
  } else if (command == kTrayCommandQuit) {
    DestroyTrayIcon();
    // 托盘退出是用户主动行为：留下标记，守护服务不再拉起。
    WriteUserExitFlag();
    DestroyWindow(GetHandle());
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 窗口级策略必须在交给 Flutter 之前处理。
  // 引擎会先吃掉 WM_CLOSE，等它返回时窗口已经被销毁，托盘就来不及接管了。
  if (message == WM_GETMINMAXINFO) {
    // 限制最小尺寸，避免窗口被拖得太窄导致布局错位。
    auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
    UINT dpi = GetDpiForWindow(hwnd);
    double scale = dpi > 0 ? dpi / 96.0 : 1.0;
    info->ptMinTrackSize.x = static_cast<LONG>(kMinWindowWidth * scale);
    info->ptMinTrackSize.y = static_cast<LONG>(kMinWindowHeight * scale);
    return 0;
  }

  if (message == WM_CLOSE && minimize_to_tray_) {
    // 关闭按钮只收进托盘，接收服务继续在后台跑。
    close_requested_ = true;
    // 收进托盘也算一次"用户认可的窗口状态"，记下来下次照这个开。
    SaveWindowPlacement();
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }

  // 拖完/改完尺寸松手：这时候的位置和大小才是用户想要的，落盘。
  if (message == WM_EXITSIZEMOVE) {
    SaveWindowPlacement();
  }
  // 托盘「退出」走的是 DestroyWindow，没有 WM_CLOSE，在这里补一次。
  if (message == WM_DESTROY) {
    SaveWindowPlacement();
  }
  // 最大化/还原不产生 WM_EXITSIZEMOVE（双击标题栏、Win+↑），
  // 这里只更新"正常态"矩形，写盘留到关闭时，避免每次 WM_SIZE 都碰注册表。
  if (message == WM_SIZE || message == WM_MOVE) {
    if (!IsIconic(hwnd) && !IsZoomed(hwnd)) {
      RECT rc{};
      if (GetWindowRect(hwnd, &rc)) last_normal_rect_ = rc;
    }
  }

  // 窗口可见性变了就通知 Dart：不可见时把 ticker 全部静音。
  // WM_SHOWWINDOW 覆盖显示/隐藏（收进托盘、静默启动后手动唤起），
  // WM_SIZE 覆盖最小化/还原——最小化不产生 WM_SHOWWINDOW。
  if (message == WM_SHOWWINDOW) {
    // 这条消息是"即将显示/隐藏"，此刻查 IsWindowVisible 还拿到旧值，
    // 必须按 wParam（TRUE=将要显示）表态。
    NotifyWindowVisibility(false, wparam != 0 ? 1 : 0);
  } else if (message == WM_SIZE) {
    NotifyWindowVisibility();
  }

  // 主窗口重新获得焦点（点任务栏、Alt+Tab、点桌面通知的空白处…）时，
  // 桌面提醒必须立刻退场，改由应用内弹层接管（规则 2/5 的"同时关闭"）。
  //
  // 前提是"用户真的回到了主窗口"。窗口还藏着的也会收到 WM_ACTIVATE——系统在
  // 前台窗口被隐藏后会把激活权还回同一个线程，这条消息不带任何"用户回来了"
  // 的含义。不判可见性的话，收托盘期间一弹气泡就会被自己收掉，用户根本
  // 没机会点"接收"。
  if (message == WM_ACTIVATE && LOWORD(wparam) != WA_INACTIVE &&
      IsWindowVisible(hwnd) && !IsIconic(hwnd)) {
    if ((toast_window_ != nullptr && IsWindowVisible(toast_window_)) ||
        (bubble_window_ != nullptr && IsWindowVisible(bubble_window_))) {
      WispDbgLog("WM_ACTIVATE: desktop surfaces retreat");
      SetTrayFlashing(false);
      HideToast();
      // 主窗口已经在前台了，浮层立刻消失，不演退场动画。
      HideBubble(/*animate=*/false);
      // 收起置顶浮层会让 DWM 重合成那块区域，主窗口可能出现黑块，
      // 紧接着连着重绘几次把黑块刷掉。
      ForceMainWindowRepaint();
      ScheduleRestoreRedraws();
      InvokeDart("onWindowRestored", flutter::EncodableMap{});
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_TIMER:
      // 启动兜底：Dart 一直没表态（设置读失败/通道异常）就照常显示窗口。
      if (wparam == kStartupTimerId) {
        KillTimer(hwnd, kStartupTimerId);
        startup_timer_ = 0;
        startup_decided_ = true;
        MaybeShowOnStartup(true);
        return 0;
      }
      // 恢复窗口后的延迟补绘（Impeller 表面重建是异步的）。
      if (wparam == kRestoreRedrawTimerId) {
        RunRestoreRedrawStep();
        return 0;
      }
      // 托盘闪烁：右上角品牌色徽章呼吸（帧序列，每帧缓存）。
      if (wparam == kFlashTimerId && flashing_) {
        flash_frame_ = (flash_frame_ + 1) % kFlashFrames;
        if (g_badge_icons[flash_frame_] == nullptr) {
          g_badge_icons[flash_frame_] = CreateBadgeIcon(flash_frame_);
        }
        tray_data_.hIcon = g_badge_icons[flash_frame_];
        Shell_NotifyIconW(NIM_MODIFY, &tray_data_);
        return 0;
      }
      break;

    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case WM_DROPFILES: {
      // 拖拽发送：资源管理器把路径放进 HDROP，一次取干后交回 Dart。
      // 文件夹的递归展开在 Dart 侧做（与「选文件夹」共用一套逻辑），
      // 原生层只负责把 Windows 的宽字符路径转成 UTF-8。
      HDROP drop = reinterpret_cast<HDROP>(wparam);
      const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      flutter::EncodableList paths;
      for (UINT i = 0; i < count; ++i) {
        const UINT length = DragQueryFileW(drop, i, nullptr, 0);
        if (length == 0) continue;
        std::wstring path(static_cast<size_t>(length) + 1, L'\0');
        const UINT copied =
            DragQueryFileW(drop, i, path.data(), length + 1);
        if (copied == 0) continue;
        path.resize(copied);
        const int bytes = WideCharToMultiByte(CP_UTF8, 0, path.c_str(),
                                              static_cast<int>(path.size()),
                                              nullptr, 0, nullptr, nullptr);
        if (bytes <= 0) continue;
        std::string utf8(static_cast<size_t>(bytes), '\0');
        WideCharToMultiByte(CP_UTF8, 0, path.c_str(),
                            static_cast<int>(path.size()), utf8.data(), bytes,
                            nullptr, nullptr);
        paths.emplace_back(utf8);
      }
      DragFinish(drop);
      if (!paths.empty()) {
        InvokeDart("onFilesDropped",
                   flutter::EncodableMap{
                       {flutter::EncodableValue("paths"),
                        flutter::EncodableValue(paths)},
                   });
      }
      return 0;
    }

    case kTrayMessage: {
      switch (LOWORD(lparam)) {
        case WM_LBUTTONDBLCLK:
          RestoreWindow();
          return 0;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
          ShowTrayMenu();
          return 0;
        default:
          break;
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
