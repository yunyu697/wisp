#include "flutter_window.h"

#include <algorithm>
#include <cctype>
#include <gdiplus.h>
#include <optional>
#include <shellapi.h>
#include <string>
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

// Timer ids。主窗口 2（托盘闪烁），球窗口 3/6/7/8，气泡 5，通知 9/10。
constexpr UINT_PTR kFlashTimerId = 2;
constexpr UINT_PTR kBallAnimTimerId = 3;
constexpr UINT_PTR kBubbleTimeoutTimerId = 5;
constexpr UINT_PTR kBallHoverTimerId = 6;
constexpr UINT_PTR kBallCollapseTimerId = 7;
constexpr UINT_PTR kBallLeaveTimerId = 8;
constexpr UINT_PTR kToastAnimTimerId = 9;
constexpr UINT_PTR kToastTimeoutTimerId = 10;
constexpr UINT_PTR kRestoreRedrawTimerId = 11;

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
Gdiplus::Bitmap* g_ball_img = nullptr;  // 悬浮球贴图（带 alpha 阴影）
IStream* g_ball_stream = nullptr;       // Bitmap::FromStream 要求流保活

void EnsureGdiplus() {
  if (g_gdiplus_token != 0) return;
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::Status st = GdiplusStartup(&g_gdiplus_token, &input, nullptr);
  WispDbgLog("GdiplusStartup status=" + std::to_string((int)st) +
             " token=" + std::to_string(g_gdiplus_token));
}

void ShutdownGdiplus() {
  delete g_ball_img;
  g_ball_img = nullptr;
  if (g_ball_stream != nullptr) {
    g_ball_stream->Release();
    g_ball_stream = nullptr;
  }
  if (g_gdiplus_token != 0) {
    Gdiplus::GdiplusShutdown(g_gdiplus_token);
    g_gdiplus_token = 0;
  }
}

// 从 RCDATA 资源加载 PNG。
void LoadBallImage() {
  if (g_ball_img != nullptr) return;
  HRSRC res = FindResourceW(GetModuleHandle(nullptr), MAKEINTRESOURCEW(BALL_PNG),
                            RT_RCDATA);
  if (res == nullptr) {
    WispDbgLog("LoadBallImage FindResource failed");
    return;
  }
  HGLOBAL handle = LoadResource(nullptr, res);
  if (handle == nullptr) {
    WispDbgLog("LoadBallImage LoadResource failed");
    return;
  }
  const void* data = LockResource(handle);
  const DWORD size = SizeofResource(nullptr, res);
  if (data == nullptr || size == 0) return;

  HGLOBAL copy = GlobalAlloc(GMEM_MOVEABLE, size);
  if (copy == nullptr) return;
  void* dst = GlobalLock(copy);
  memcpy(dst, data, size);
  GlobalUnlock(copy);
  HRESULT hr = CreateStreamOnHGlobal(copy, TRUE, &g_ball_stream);
  if (FAILED(hr)) {
    WispDbgLog("LoadBallImage CreateStreamOnHGlobal failed");
    GlobalFree(copy);
    return;
  }
  g_ball_img = Gdiplus::Bitmap::FromStream(g_ball_stream);
  if (g_ball_img == nullptr) {
    WispDbgLog("LoadBallImage FromStream failed");
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

  // 把画布内容提交到窗口，(x, y) 是窗口左上角的屏幕坐标（可为 nullptr 保持）。
  void Present(HWND hwnd, const POINT* dst) {
    if (dc_ == nullptr) return;
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
int DrawWrapped(Gdiplus::Graphics& g, const std::wstring& text,
                const Gdiplus::RectF& rc, float px, bool bold, COLORREF color) {
  Gdiplus::Font* font = UiFont(px, bold);
  Gdiplus::SolidBrush brush(Gdiplus::Color(255, GetRValue(color),
                                           GetGValue(color), GetBValue(color)));
  Gdiplus::StringFormat format;
  format.SetLineAlignment(Gdiplus::StringAlignmentNear);
  g.DrawString(text.c_str(), static_cast<INT>(text.size()), font, rc, &format,
               &brush);
  delete font;
  return 2;  // 布局高度由调用方固定为两行。
}

// 带 alpha 的贴图绘制。
void DrawImageAlpha(Gdiplus::Graphics& g, Gdiplus::Bitmap* img,
                    const Gdiplus::RectF& dst, BYTE alpha) {
  if (img == nullptr) return;
  if (alpha >= 255) {
    g.DrawImage(img, dst);
    return;
  }
  Gdiplus::ImageAttributes attr;
  Gdiplus::ColorMatrix matrix{{
      {1, 0, 0, 0, 0},
      {0, 1, 0, 0, 0},
      {0, 0, 1, 0, 0},
      {0, 0, 0, alpha / 255.0f, 0},
      {0, 0, 0, 0, 1},
  }};
  attr.SetColorMatrix(&matrix);
  g.DrawImage(img, dst, 0, 0, static_cast<Gdiplus::REAL>(img->GetWidth()),
              static_cast<Gdiplus::REAL>(img->GetHeight()), Gdiplus::UnitPixel,
              &attr);
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
        if (!w->ball_expanded_ && w->ball_snapped_ &&
            w->ball_hover_timer_ == 0) {
          // 把手上悬停：按设置的延时展开。
          w->ball_hover_timer_ =
              SetTimer(hwnd, kBallHoverTimerId, w->ball_hover_delay_ms_, nullptr);
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
      if (w->ball_expanded_ && w->ball_snapped_ && w->ball_anim_kind_ == 0) {
        // 鼠标离开球：稍后缩回把手。
        KillTimer(hwnd, kBallLeaveTimerId);
        w->ball_leave_timer_ = SetTimer(hwnd, kBallLeaveTimerId, 700, nullptr);
      }
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
        // 按下立刻展开成完整球（从把手直接拖动时体验更顺）。
        if (!w->ball_expanded_) w->ExpandBall(false);
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
        w->ball_anim_phase_++;
        int phase = w->ball_anim_phase_;
        int kind = w->ball_anim_kind_;
        if (kind == 1 || kind == 2) {
          // 展开/收起：12 帧，缓动。
          int total = 12;
          float t = phase / static_cast<float>(total);
          if (kind == 2) t = 1.0f - t;
          if (t > 1) t = 1;
          float eased = 1 - (1 - t) * (1 - t);  // ease-out
          BYTE alpha = static_cast<BYTE>(255 * (0.35f + 0.65f * eased));
          w->RenderBall(kind == 1 ? eased : 1 - eased, alpha, 1.0f);
          if (phase >= total) {
            KillTimer(hwnd, kBallAnimTimerId);
            w->ball_anim_timer_ = 0;
            w->ball_anim_kind_ = 0;
            w->ball_expanded_ = kind == 1;
            w->RenderBall(w->ball_expanded_ ? 1 : 0, 255, 1.0f);
            if (w->ball_expanded_ && w->ball_snapped_) {
              // 展开后鼠标若不在球上，几秒后自动缩回。
              w->ball_collapse_timer_ =
                  SetTimer(hwnd, kBallCollapseTimerId, 3000, nullptr);
            }
          }
        } else if (kind == 3) {
          // 提示动画：8 帧渐入 + 32 帧两次呼吸脉冲。
          // 结束后保持展开，等 Dart 在流程结束点明确调 collapseBall。
          BYTE alpha;
          float scale = 1.0f;
          if (phase < 8) {
            alpha = static_cast<BYTE>(60 + (255 - 60) * phase / 7);
          } else if (phase < 40) {
            int t = (phase - 8) % 16;
            float k = t < 8 ? t / 8.0f : (15 - t) / 8.0f;
            alpha = static_cast<BYTE>(195 + 60 * k);
            scale = 1.0f + 0.05f * k;
          } else {
            alpha = 255;
          }
          w->RenderBall(1, alpha, scale);
          if (phase >= 40) {
            KillTimer(hwnd, kBallAnimTimerId);
            w->ball_anim_timer_ = 0;
            w->ball_anim_kind_ = 0;
            w->RenderBall(1, 255, 1.0f);
          }
        }
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
        if (w->ball_snapped_ && w->ball_expanded_ && w->ball_anim_kind_ == 0) {
          w->CollapseBall();
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
      if (wparam == kBubbleTimeoutTimerId) {
        KillTimer(hwnd, kBubbleTimeoutTimerId);
        if (g_instance != nullptr) {
          g_instance->HideBubble();
          g_instance->InvokeDart("onBubbleTimeout", flutter::EncodableMap{});
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
        w->toast_anim_phase_++;
        int total = 14;
        float t = w->toast_anim_phase_ / static_cast<float>(total);
        if (t > 1) t = 1;
        float eased = 1 - (1 - t) * (1 - t);
        w->RenderToast(eased);
        if (w->toast_anim_phase_ >= total) {
          KillTimer(hwnd, kToastAnimTimerId);
          w->toast_anim_timer_ = 0;
          w->RenderToast(1);
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
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // 如果用户在首帧渲染完成之前就点了关闭，别再把窗口弹回来。
    if (!close_requested_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  CreateTrayIcon();
  EnsureGdiplus();
  LoadBallImage();

  // 拖拽发送：主窗口注册为拖放目标，文件/文件夹拖进来就加入待发清单。
  // 子窗口（Flutter 视图）没注册也没关系，Shell 会沿父链找到这个顶层窗口。
  DragAcceptFiles(GetHandle(), TRUE);

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
  // 初始位置：优先用上次记忆的位置，否则主屏工作区右下角。
  RECT work;
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  int x;
  int y;
  if (ball_saved_pos_.x >= 0 && ball_saved_pos_.y >= 0) {
    x = ball_saved_pos_.x;
    y = ball_saved_pos_.y;
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

  // 记忆位置若带吸附状态，恢复之（展开后照常自动缩回把手）。
  if (ball_saved_pos_.x >= 0 && ball_saved_snapped_ &&
      ball_saved_edge_ >= 0 && ball_saved_edge_ <= 3) {
    ball_snapped_ = true;
    ball_edge_ = ball_saved_edge_;
  } else {
    ball_snapped_ = false;
  }
  ball_expanded_ = true;
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
  DestroyWindow(ball_window_);
  ball_window_ = nullptr;
  ball_expanded_ = false;
  ball_snapped_ = false;
  ball_hover_tracked_ = false;
}

void FlutterWindow::StopBallAnims() {
  if (ball_window_ == nullptr) return;
  KillTimer(ball_window_, kBallAnimTimerId);
  KillTimer(ball_window_, kBallHoverTimerId);
  KillTimer(ball_window_, kBallCollapseTimerId);
  KillTimer(ball_window_, kBallLeaveTimerId);
  ball_anim_timer_ = 0;
  ball_hover_timer_ = 0;
  ball_collapse_timer_ = 0;
  ball_leave_timer_ = 0;
  ball_anim_kind_ = 0;
}

RECT FlutterWindow::BallWorkArea() const {
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
  if (animate && ball_anim_kind_ == 0) {
    ball_expanded_ = true;
    StartBallAnim(1);
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
  if (ball_anim_kind_ == 0) {
    ball_expanded_ = false;
    StartBallAnim(2);
  }
}

// 有新传输请求时：展开并播放提示动画。
void FlutterWindow::ShowBallAlert() {
  if (ball_window_ == nullptr) return;
  StopBallAnims();
  ball_expanded_ = true;
  StartBallAnim(3);
  ShowWindow(ball_window_, SW_SHOWNOACTIVATE);
}

void FlutterWindow::StartBallAnim(int kind) {
  if (ball_window_ == nullptr) return;
  KillTimer(ball_window_, kBallAnimTimerId);
  ball_anim_kind_ = kind;
  ball_anim_phase_ = 0;
  UINT interval = kind == 3 ? 40 : 16;
  ball_anim_timer_ = SetTimer(ball_window_, kBallAnimTimerId, interval, nullptr);
  // 第一帧立即画出来，避免定时器 16ms 的空窗。
  ball_anim_phase_ = 0;
  if (kind == 1) {
    RenderBall(0, 89, 1.0f);
  } else if (kind == 2) {
    RenderBall(1, 255, 1.0f);
  } else if (kind == 3) {
    RenderBall(1, 60, 1.0f);
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

  int inset = ScaleFor(ball_window_, kHandleOutset);
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
  SetWindowPos(ball_window_, nullptr, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);

  // 通知 Dart 记忆吸附位置。
  InvokeDart("onBallPosition",
             flutter::EncodableMap{
                 {"x", flutter::EncodableValue(x)},
                 {"y", flutter::EncodableValue(y)},
                 {"snapped", flutter::EncodableValue(true)},
                 {"edge", flutter::EncodableValue(edge)},
             });

  // 吸附后稍停片刻缩回把手。
  KillTimer(ball_window_, kBallCollapseTimerId);
  ball_collapse_timer_ = SetTimer(ball_window_, kBallCollapseTimerId, 700,
                                  nullptr);
}

// 渲染悬浮球。expand_t: 0=把手 1=完整球；alpha 全局不透明度；scale 呼吸缩放。
void FlutterWindow::RenderBall(float expand_t, BYTE alpha, float scale) {
  if (ball_window_ == nullptr) return;
  if (g_ball_img == nullptr) {
    WispDbgLog("RenderBall: ball image is null!");
    return;
  }
  HWND hwnd = ball_window_;
  int size = ScaleFor(hwnd, kBallWindow);

  LayeredCanvas canvas;
  if (!canvas.Begin(hwnd, size, size)) return;
  Gdiplus::Graphics& g = *canvas.graphics();

  // 把手（仅吸附时画；展开过程中随 expand_t 淡出）。
  if (ball_snapped_ && expand_t < 1) {
    BYTE handle_alpha = static_cast<BYTE>(230 * (1 - expand_t));
    float hs = static_cast<float>(ScaleFor(hwnd, kHandleSize));
    float hl = static_cast<float>(ScaleFor(hwnd, kHandleLength));
    float c = size / 2.0f;
    Gdiplus::RectF pill;
    if (ball_edge_ == 0) {
      pill = Gdiplus::RectF(-hs / 2, c - hl / 2, hs * 1.6f, hl);
    } else if (ball_edge_ == 1) {
      pill = Gdiplus::RectF(size - hs * 1.1f, c - hl / 2, hs * 1.6f, hl);
    } else if (ball_edge_ == 2) {
      pill = Gdiplus::RectF(c - hl / 2, -hs / 2, hl, hs * 1.6f);
    } else {
      pill = Gdiplus::RectF(c - hl / 2, size - hs * 1.1f, hl, hs * 1.6f);
    }
    FillRound(g, pill, hs * 0.8f, kBrand, handle_alpha);
    // 把手上的两个白点（呼吸感）。
    float dot = hs * 0.22f;
    Gdiplus::SolidBrush white(Gdiplus::Color(handle_alpha, 255, 255, 255));
    for (int i = -1; i <= 1; i += 2) {
      float cxp = ball_edge_ <= 1 ? pill.X + pill.Width / 2
                                  : c + i * hl * 0.18f;
      float cyp = ball_edge_ <= 1 ? c + i * hl * 0.18f
                                  : pill.Y + pill.Height / 2;
      g.FillEllipse(&white, cxp - dot, cyp - dot, dot * 2, dot * 2);
    }
  }

  // 球体。
  if (expand_t > 0) {
    float visual = size * (kBallWindow - 2.0f * kHandleOutset) / kBallWindow;
    float draw_size = visual * scale;
    // 展开过程中球体从边缘滑出来。
    float slide = (1 - expand_t) * size * 0.3f;
    float dx = 0;
    float dy = 0;
    if (ball_snapped_) {
      if (ball_edge_ == 0) dx = -slide;
      if (ball_edge_ == 1) dx = slide;
      if (ball_edge_ == 2) dy = -slide;
      if (ball_edge_ == 3) dy = slide;
    }
    float cx = size / 2.0f + dx;
    float cy = size / 2.0f + dy;
    Gdiplus::RectF dst(cx - draw_size / 2, cy - draw_size / 2, draw_size,
                       draw_size);
    DrawImageAlpha(g, g_ball_img, dst, alpha);
  }

  canvas.Present(hwnd, nullptr);
}

// ---------------------------------------------------------------------------
// 通知卡片（替代系统 toast；ask / progress / done 三态）
// ---------------------------------------------------------------------------

void FlutterWindow::ShowToast(const std::wstring& title,
                              const std::wstring& body, int mode,
                              const std::wstring& progress) {
  if (toast_window_ == nullptr) {
    CreateToastWindow();
    if (toast_window_ == nullptr) return;
  }
  toast_title_ = title;
  toast_body_ = body;
  toast_mode_ = mode;
  toast_progress_ = progress;

  // 位置：工作区右下角。锚点在这里算一次，动画帧只在这个锚点上做位移。
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
  RenderToast(1);
  KillTimer(toast_window_, kToastTimeoutTimerId);
  toast_timeout_timer_ =
      SetTimer(toast_window_, kToastTimeoutTimerId, 8000, nullptr);
  // 滑入动画（仅在全新弹出时播放）。
  KillTimer(toast_window_, kToastAnimTimerId);
  toast_anim_phase_ = 0;
  toast_anim_timer_ = SetTimer(toast_window_, kToastAnimTimerId, 16, nullptr);
}

void FlutterWindow::UpdateToast(const std::wstring& body, int mode,
                                const std::wstring& progress) {
  if (toast_window_ == nullptr || !IsWindowVisible(toast_window_)) return;
  toast_body_ = body;
  toast_mode_ = mode;
  toast_progress_ = progress;
  RenderToast(1);
  // 有内容更新就顺延存活时间（进度每 200ms 一次，卡片保持到传输结束）。
  KillTimer(toast_window_, kToastTimeoutTimerId);
  toast_timeout_timer_ =
      SetTimer(toast_window_, kToastTimeoutTimerId, 8000, nullptr);
}

void FlutterWindow::HideToast() {
  if (toast_window_ == nullptr) return;
  KillTimer(toast_window_, kToastTimeoutTimerId);
  toast_timeout_timer_ = 0;
  KillTimer(toast_window_, kToastAnimTimerId);
  toast_anim_timer_ = 0;
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

  if (mode == 1) {
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

  const bool done = mode == 2;
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

// slide_t: 0=完全在屏幕外 1=就位。
//
// 位置必须相对**固定锚点**算，不能相对"当前窗口矩形"算：以前每帧拿
// GetWindowRect 再加位移，14 帧滑入动画会把窗口一路推到 x=6300（屏幕才 3840），
// 于是通知"弹出来了但看不见"。这正是桌面通知不显示的根因。
void FlutterWindow::RenderToast(float slide_t) {
  if (toast_window_ == nullptr) return;
  HWND hwnd = toast_window_;
  int win_w = ScaleFor(hwnd, kCardWidth + kCardMargin * 2);
  int win_h = ScaleFor(hwnd, kCardHeight + kCardMargin * 2);

  int offset = static_cast<int>((1 - slide_t) * (win_w + ScaleFor(hwnd, 8)));
  POINT dst{toast_anchor_.x + offset, toast_anchor_.y};

  LayeredCanvas canvas;
  if (!canvas.Begin(hwnd, win_w, win_h)) return;
  g_toast_buttons = DrawCardContent(*canvas.graphics(), hwnd, win_w, win_h,
                                    toast_title_, toast_body_, toast_mode_,
                                    toast_progress_);
  canvas.Present(hwnd, &dst);
}

void FlutterWindow::HandleToastClick(POINT pt) {
  if (toast_mode_ == 1) return;  // 进度模式不可点。
  const char* action = nullptr;
  if (PtInRect(&g_toast_buttons.primary, pt)) {
    action = toast_mode_ == 2 ? "openFolder" : "accept";
  } else if (PtInRect(&g_toast_buttons.secondary, pt)) {
    if (toast_mode_ == 2) {
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
  bubble_timeout_timer_ = 0;
  DestroyWindow(bubble_window_);
  bubble_window_ = nullptr;
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

  // 把手：与 RenderBall 里的 pill 位置保持一致。
  const float hs = static_cast<float>(ScaleFor(ball_window_, kHandleSize));
  const float hl = static_cast<float>(ScaleFor(ball_window_, kHandleLength));
  const float c = size / 2.0f;
  float left = 0;
  float top = 0;
  float w = 0;
  float h = 0;
  if (ball_edge_ == 0) {
    left = -hs / 2;
    top = c - hl / 2;
    w = hs * 1.6f;
    h = hl;
  } else if (ball_edge_ == 1) {
    left = size - hs * 1.1f;
    top = c - hl / 2;
    w = hs * 1.6f;
    h = hl;
  } else if (ball_edge_ == 2) {
    left = c - hl / 2;
    top = -hs / 2;
    w = hl;
    h = hs * 1.6f;
  } else {
    left = c - hl / 2;
    top = size - hs * 1.1f;
    w = hl;
    h = hs * 1.6f;
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

  SetWindowPos(bubble_window_, nullptr, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  ShowWindow(bubble_window_, SW_SHOWNOACTIVATE);
  RenderBubble();

  KillTimer(bubble_window_, kBubbleTimeoutTimerId);
  bubble_timeout_timer_ =
      SetTimer(bubble_window_, kBubbleTimeoutTimerId, 60000, nullptr);
}

void FlutterWindow::UpdateBubble(const std::wstring& body, int mode,
                                 const std::wstring& progress) {
  if (bubble_window_ == nullptr || !IsWindowVisible(bubble_window_)) return;
  bubble_body_ = body;
  bubble_mode_ = mode;
  bubble_progress_ = progress;
  RenderBubble();
}

void FlutterWindow::HideBubble() {
  if (bubble_window_ == nullptr) return;
  KillTimer(bubble_window_, kBubbleTimeoutTimerId);
  bubble_timeout_timer_ = 0;
  ShowWindow(bubble_window_, SW_HIDE);
}

void FlutterWindow::RenderBubble() {
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
  canvas.Present(hwnd, &bubble_anchor_);
}

void FlutterWindow::HandleBubbleClick(POINT pt) {
  const char* action = nullptr;
  if (bubble_mode_ != 1) {
    if (PtInRect(&g_bubble_buttons.primary, pt)) {
      action = bubble_mode_ == 2 ? "openFolder" : "accept";
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

void FlutterWindow::RestoreWindow() {
  HWND handle = GetHandle();
  if (handle == nullptr) {
    return;
  }
  ShowWindow(handle, SW_RESTORE);
  BringWindowToTop(handle);
  SetForegroundWindow(handle);
  // 用户回到主窗口：桌面上的提醒全部退场，后续进度/完成也改由主窗口呈现，
  // Dart 侧收到 onWindowRestored 后会停止推进通知流程。
  SetTrayFlashing(false);
  HideToast();
  HideBubble();
  // Impeller 从隐藏态恢复时交换链还停留在黑帧，必须强制重绘。
  // 但只调一次不够：ShowWindow 之后视图尺寸/表面是异步重建的，紧跟着的那次
  // ForceRedraw 往往落在"表面还没就绪"的空窗里，于是从托盘/悬浮球回来仍然黑屏。
  // 这里再补一次延迟重绘（120ms 后表面已就绪），并在 400ms 兜底刷新一次。
  if (flutter_controller_) {
    flutter_controller_->ForceRedraw();
  }
  RedrawWindow(handle, nullptr, nullptr,
               RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
  KillTimer(handle, kRestoreRedrawTimerId);
  restore_redraw_timer_ = SetTimer(handle, kRestoreRedrawTimerId, 120, nullptr);
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
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }

  // 主窗口重新获得焦点（点任务栏、Alt+Tab、点桌面通知的空白处…）时，
  // 桌面提醒必须立刻退场，改由应用内弹层接管（规则 2/5 的"同时关闭"）。
  if (message == WM_ACTIVATE && LOWORD(wparam) != WA_INACTIVE) {
    if ((toast_window_ != nullptr && IsWindowVisible(toast_window_)) ||
        (bubble_window_ != nullptr && IsWindowVisible(bubble_window_))) {
      SetTrayFlashing(false);
      HideToast();
      HideBubble();
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
      // 恢复窗口后的延迟补绘（Impeller 表面重建是异步的）。
      if (wparam == kRestoreRedrawTimerId) {
        KillTimer(hwnd, kRestoreRedrawTimerId);
        restore_redraw_timer_ = 0;
        if (flutter_controller_) flutter_controller_->ForceRedraw();
        RedrawWindow(hwnd, nullptr, nullptr,
                     RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
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
