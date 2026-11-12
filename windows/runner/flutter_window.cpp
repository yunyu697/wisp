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

// ---------------------------------------------------------------------------
// 开机启动（HKCU Run 项）
// ---------------------------------------------------------------------------

// 用 HKCU 而不是 HKLM：登录自启不需要管理员权限，普通用户就能开关，
// 不会像"服务守护"那样弹 UAC。卸载程序时这条值由安装器负责清理。
constexpr wchar_t kAutoStartRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kAutoStartValueName[] = L"Wisp";

std::wstring CurrentExecutablePath() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD copied = GetModuleFileNameW(
        nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (copied == 0) return L"";
    // 返回值刚好等于缓冲区大小说明可能被截断（没有 null 结尾），放大重试。
    if (copied < path.size() - 1) {
      path.resize(copied);
      return path;
    }
    path.resize(path.size() * 2);
  }
}

std::wstring AutoStartCommand() {
  const std::wstring exe = CurrentExecutablePath();
  if (exe.empty()) return L"";
  // 路径含空格（Program Files）时必须加引号，否则 Run 项会把
  // "C:\Program" 当可执行文件、后面全当参数，开机直接启动失败。
  return L"\"" + exe + L"\"";
}

bool ReadAutoStart() {
  const std::wstring exe = CurrentExecutablePath();
  if (exe.empty()) return false;
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kAutoStartRunKey, 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return false;
  }
  wchar_t buffer[2048] = {};
  DWORD bytes = sizeof(buffer);
  DWORD type = 0;
  const LONG status = RegQueryValueExW(
      key, kAutoStartValueName, nullptr, &type,
      reinterpret_cast<LPBYTE>(buffer), &bytes);
  RegCloseKey(key);
  if (status != ERROR_SUCCESS ||
      (type != REG_SZ && type != REG_EXPAND_SZ)) {
    return false;
  }
  std::wstring value(buffer, bytes / sizeof(wchar_t));
  while (!value.empty() && value.back() == L'\0') value.pop_back();
  // 只认指向当前这份安装的项：另一份 Wisp 留下的 Run 值不该让开关显示
  // "已开启"——那样用户点关闭也删不掉它，开关就永远卡住了。
  return value.find(exe) != std::wstring::npos;
}

bool WriteAutoStart(bool enabled) {
  const std::wstring command = AutoStartCommand();
  if (enabled && command.empty()) return false;
  HKEY key = nullptr;
  if (enabled) {
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kAutoStartRunKey, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
      return false;
    }
    const LONG status = RegSetValueExW(
        key, kAutoStartValueName, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
    return status == ERROR_SUCCESS;
  }
  // 关闭是幂等的：值本来就不存在也算成功。
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kAutoStartRunKey, 0, KEY_WRITE,
                    &key) != ERROR_SUCCESS) {
    return true;
  }
  const LONG status = RegDeleteValueW(key, kAutoStartValueName);
  RegCloseKey(key);
  return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
}

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
constexpr wchar_t kToastClass[] = L"WISP_TOAST";

// --- 通知卡片几何（内容区，另加阴影边距） ---
// 桌面通知卡用一套固定的几何与字体。
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
constexpr int kToastFadeMs = 200;

// --- 缓动 ---
float Clamp01(float x) { return x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x); }

float EaseOutCubic(float x) {
  x = Clamp01(x);
  const float y = 1.0f - x;
  return 1.0f - y * y * y;
}

// Timer ids。主窗口 2/11/17，通知卡 9/10。球与气泡的计时器已随悬浮球退役删除。
constexpr UINT_PTR kFlashTimerId = 2;
constexpr UINT_PTR kToastAnimTimerId = 9;
constexpr UINT_PTR kToastTimeoutTimerId = 10;
constexpr UINT_PTR kRestoreRedrawTimerId = 11;
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

// The single FlutterWindow, used to route toast messages.
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
// GDI+ 生命周期
// ---------------------------------------------------------------------------

ULONG_PTR g_gdiplus_token = 0;
// 桌面通知卡的图形全部用 GDI+ 现画，不依赖任何位图贴图。

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
// 所以 200% 缩放下字号只有设计值的一半——通知卡"字体特别小"就是这么来的。
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

// 通知卡片左上角的迷你图标：与应用图标（方案 C「不分彼此」）同一套构图。
// 坐标全部按 assets/icon/wisp_icon.svg 的 1024 画布归一化，改图标时改这里
// 和 macOS WispCardView.drawIcon(in:) 两处即可，不要凭感觉挪像素。
//   squircle 底 → 后置描边文件卡 → 前置白色消息卡（带气泡尾）
//   → 两条青绿文字线 → 右上角珊瑚点
void DrawMiniIcon(Gdiplus::Graphics& g, const Gdiplus::RectF& rc) {
  const float s = std::min(rc.Width, rc.Height);
  const float x = rc.X + (rc.Width - s) / 2.0f;
  const float y = rc.Y + (rc.Height - s) / 2.0f;
  const auto box = [&](float nx, float ny, float nw, float nh) {
    return Gdiplus::RectF(x + s * nx, y + s * ny, s * nw, s * nh);
  };

  // 青绿 squircle 底板（135° 渐变，与 app_colors.dart 的 teal / tealLight 同值）。
  Gdiplus::RectF bg_rc(x, y, s, s);
  Gdiplus::GraphicsPath* bg = RoundedRect(bg_rc, s * 0.235f);
  Gdiplus::LinearGradientBrush grad(
      bg_rc, Gdiplus::Color(255, 58, 200, 203),
      Gdiplus::Color(255, 14, 124, 134), 45.0f, false);
  g.FillPath(&grad, bg);
  delete bg;

  // 后置文件卡：只描边、倾斜 -9°，别填白，否则两层白卡会糊成一块。
  Gdiplus::GraphicsPath* back =
      RoundedRect(box(0.410f, 0.180f, 0.422f, 0.445f), s * 0.055f);
  const Gdiplus::PointF pivot(x + s * 0.617f, y + s * 0.406f);
  Gdiplus::Matrix spin;
  spin.RotateAt(-9.0f, pivot);
  back->Transform(&spin);
  Gdiplus::Pen outline(Gdiplus::Color(160, 255, 255, 255), s * 0.018f);
  outline.SetLineJoin(Gdiplus::LineJoinRound);
  g.DrawPath(&outline, back);
  delete back;

  Gdiplus::SolidBrush white(Gdiplus::Color(255, 255, 255, 255));

  // 前置消息卡 + 左下角实心气泡尾。
  Gdiplus::GraphicsPath* front =
      RoundedRect(box(0.188f, 0.406f, 0.500f, 0.360f), s * 0.102f);
  g.FillPath(&white, front);
  delete front;
  Gdiplus::PointF tail_pts[3] = {
      Gdiplus::PointF(x + s * 0.293f, y + s * 0.715f),
      Gdiplus::PointF(x + s * 0.176f, y + s * 0.855f),
      Gdiplus::PointF(x + s * 0.305f, y + s * 0.715f),
  };
  Gdiplus::GraphicsPath tail;
  tail.AddPolygon(tail_pts, 3);
  g.FillPath(&white, &tail);

  // 卡内两条文字线用的是底板深青，不是白色。
  Gdiplus::SolidBrush ink(Gdiplus::Color(255, 14, 124, 134));
  const float bars[2][4] = {
      {0.277f, 0.531f, 0.320f, 0.047f},
      {0.277f, 0.621f, 0.100f, 0.047f},
  };
  for (const auto& b : bars) {
    Gdiplus::GraphicsPath* bar =
        RoundedRect(box(b[0], b[1], b[2], b[3]), s * 0.024f);
    g.FillPath(&ink, bar);
    delete bar;
  }

  // 珊瑚圆点：正在移动的那份数据。
  Gdiplus::SolidBrush coral(Gdiplus::Color(255, 255, 122, 89));
  g.FillEllipse(&coral, box(0.758f, 0.188f, 0.117f, 0.117f));
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

// 通知卡片按钮命中区域。
struct ToastButtons {
  RECT card{};
  RECT primary{};
  RECT secondary{};
};
ToastButtons g_toast_buttons;

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
        } else if (name == "launchAtLoginStatus") {
          // 状态一律以系统为准：用户完全可能在任务管理器里手动禁用了
          // 这一项，本地记着"开"就是一个骗人的开关。
          flutter::EncodableMap state{
              {flutter::EncodableValue("supported"),
               flutter::EncodableValue(true)},
              {flutter::EncodableValue("enabled"),
               flutter::EncodableValue(ReadAutoStart())},
          };
          result->Success(state);
        } else if (name == "setLaunchAtLogin") {
          const bool enabled = GetBool("enabled", false);
          const bool ok = WriteAutoStart(enabled);
          // 写完回读一次，不直接信"写成功"：被安全软件/组策略挡下来的
          // 情况下，开关不该显示成已开启。关掉时同理（回读应为 false）。
          result->Success(ok && ReadAutoStart() == enabled);
        } else if (name == "isWindowVisible") {
          result->Success(GetHandle() != nullptr && IsWindowVisible(GetHandle()));
        } else if (name == "windowState") {
          // 通知分流要用的是"可见 + 是否为当前激活窗口"两个维度：
          // 窗口可见但被别的程序盖住时，桌面通知照样得弹。
          HWND main = GetHandle();
          const bool visible = main != nullptr && IsWindowVisible(main);
          const bool active = main != nullptr && GetForegroundWindow() == main;
          // 常驻悬浮球已退役：三个 ball* 键保留但恒 false（Dart 侧同样恒 false）。
          flutter::EncodableMap state{
              {flutter::EncodableValue("visible"), flutter::EncodableValue(visible)},
              {flutter::EncodableValue("active"), flutter::EncodableValue(active)},
              {flutter::EncodableValue("ballEnabled"), flutter::EncodableValue(false)},
              {flutter::EncodableValue("ballExpanded"), flutter::EncodableValue(false)},
              {flutter::EncodableValue("ballSnapped"), flutter::EncodableValue(false)},
          };
          result->Success(state);
        } else if (name == "debugWindows") {
          // 自测入口用：一次性拿到桌面通知卡窗口的可见性与屏幕矩形。
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
          RECT work = ToastWorkArea();
          flutter::EncodableMap all{
              {flutter::EncodableValue("toast"), flutter::EncodableValue(describe(toast_window_))},
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
  // 通知卡窗口在启动时就建好（保持隐藏）：第一次弹的时候不用现创建，
  // 少一个"首次创建状态不对"的机会——用户反馈过"第一次不出现、第二次才出现"。
  CreateToastWindow();

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

// 不能加 const：定位依据 GetHandle() 是 Win32Window 的非 const 方法
// （旧 BallWorkArea 只读成员 HWND 所以能 const，改名后换成主窗口句柄就不行了）。
RECT FlutterWindow::ToastWorkArea() {
  // 用主窗口所在那台显示器的工作区给通知卡定位：SPI_GETWORKAREA 只给主屏，
  // 主窗口拖到副屏时通知卡应跟着落在同一块屏幕上。
  HMONITOR mon = GetHandle() != nullptr
                     ? MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST)
                     : nullptr;
  MONITORINFO mi{sizeof(MONITORINFO)};
  if (mon != nullptr && GetMonitorInfoW(mon, &mi)) return mi.rcWork;
  RECT work;
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  return work;
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
  RECT work = ToastWorkArea();
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

// 桌面通知卡片的统一绘制：返回按钮命中区（客户区坐标）。
// 常驻悬浮球与贴球气泡已退役，这一份绘制只服务桌面通知卡。
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
  // 隐藏置顶的桌面通知卡会让 DWM 把它原先占的那块区域重新
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

  // 主窗口重新获得焦点（点任务栏、Alt+Tab、点通知卡空白处…）时，
  // 桌面通知卡必须立刻退场，改由应用内弹层接管（规则 2/5 的"同时关闭"）。
  //
  // 前提是"用户真的回到了主窗口"。窗口还藏着的也会收到 WM_ACTIVATE——系统在
  // 前台窗口被隐藏后会把激活权还回同一个线程，这条消息不带任何"用户回来了"
  // 的含义。不判可见性的话，收托盘期间一弹通知卡就会被自己收掉，用户根本
  // 没机会点"接收"。
  if (message == WM_ACTIVATE && LOWORD(wparam) != WA_INACTIVE &&
      IsWindowVisible(hwnd) && !IsIconic(hwnd)) {
    if (toast_window_ != nullptr && IsWindowVisible(toast_window_)) {
      WispDbgLog("WM_ACTIVATE: desktop surfaces retreat");
      SetTrayFlashing(false);
      HideToast();
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
