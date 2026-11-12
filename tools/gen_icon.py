"""从设计源生成 Wisp 的全平台应用图标资产。

设计（第四版，2026-11-12 定稿 · 方案 C「不分彼此」· 品牌青绿）：
  青绿 squircle 底板上，一张**白色消息卡**（带气泡尾巴与两条文字线）叠在
  一张**白色描边文件卡**前，右上角一颗**珊瑚圆点**。
  读法：文字、剪贴板图片、文件在聊天里都只是同一条会话里的一条消息。
  没有缎带、没有折角线段、没有箭头 —— 16px 菜单栏也不会糊成一团。

矢量源（唯一权威，改图标请改这里，再重新光栅化）：
  assets/icon/wisp_icon.svg                        浅色主题主图
  design/icons/wisp-icon-c-teal-dark.svg           深色主题主图（工作区设计稿）
  光栅化可用 Chrome headless：
    chrome --headless=new --window-size=1024,1024 --force-device-scale-factor=1
           --default-background-color=00000000 --screenshot=wisp_icon_1024.png
           <一个 body 透明、内嵌该 SVG 的 html>
  产物固定为 1024×1024 RGBA、四角 alpha=0。

两张 1024 源图（脚本只读取，不覆盖）：
  assets/icon/wisp_icon_1024.png                    squircle 主图标
  assets/icon/wisp_icon_adaptive_foreground.png     透明底前景（青绿卡 + 描边卡 + 珊瑚点）

本脚本负责「缩放 + 格式 + 分发」，产物：
  assets/icon/wisp_icon_preview.png                 浅灰底预览
  assets/icon/wisp_icon_foreground.png             透明底前景（与 adaptive 同源）
  assets/icon/wisp_icon_legacy_1024.png            不透明四角版（旧打包链路兼容）
  windows/runner/resources/app_icon.ico            7 档 16–256
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16..1024}.png
  ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*.png   （RGB 不透明）
  android/.../res/mipmap-*/ic_launcher.png
  android/.../res/drawable-*/ic_launcher_foreground.png
  web/favicon.png · web/icons/Icon-{192,512}.png · Icon-maskable-{192,512}.png

注意：Windows 悬浮球与 macOS 悬浮球/通知卡/菜单栏的迷你 logo 都是原生层
GDI+ / AppKit **现画**的，不使用位图，也不由本脚本生成；改图形时要同步
windows/runner/flutter_window.cpp 与 macos/Runner/{MainFlutterWindow,WispOverlay}.swift。

用法：python tools/gen_icon.py
依赖：Pillow（无 numpy、无 SVG 渲染库）。
"""

from __future__ import annotations

import re
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets" / "icon"
WIN_RES = ROOT / "windows" / "runner" / "resources"
MAC_ICONS = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
IOS_ICONS = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
ANDROID_RES = ROOT / "android" / "app" / "src" / "main" / "res"
WEB = ROOT / "web"

MASTER = ASSETS / "wisp_icon_1024.png"
FOREGROUND = ASSETS / "wisp_icon_adaptive_foreground.png"
PREVIEW_BG = (245, 246, 249)
IOS_BG = (255, 255, 255)

_written: list[Path] = []


def resized(size: int, source: Path = MASTER) -> Image.Image:
    """从 1024 矢量光栅源做 Lanczos 缩放，保留 alpha。"""
    with Image.open(source) as im:
        base = im.convert("RGBA")
    return base.resize((size, size), Image.LANCZOS) if base.size != (size, size) else base.copy()


def flatten(im: Image.Image, size: int, bg: tuple[int, int, int]) -> Image.Image:
    """iOS 要求不透明 PNG：把 alpha 角填成纯色底。"""
    canvas = Image.new("RGB", (size, size), bg)
    canvas.paste(im.convert("RGBA"), (0, 0), im.convert("RGBA").getchannel("A"))
    return canvas


def save(im: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path)
    _written.append(path)


def main() -> None:
    for src in (MASTER, FOREGROUND):
        if not src.is_file():
            raise SystemExit(f"缺少设计源：{src}")

    # --- 自检：主图必须是带透明角的 squircle，前景必须透明底 ---
    with Image.open(MASTER) as probe:
        master = probe.convert("RGBA")
    assert master.size == (1024, 1024), "主图必须是 1024×1024"
    assert master.getpixel((0, 0))[3] == 0, "主图四角必须透明"
    assert master.getpixel((512, 512))[3] == 255, "主图中心必须不透明"
    with Image.open(FOREGROUND) as probe:
        fg = probe.convert("RGBA")
    assert fg.getpixel((0, 0))[3] == 0, "前景图必须是透明底"

    # --- assets/icon 派生图 ---
    preview = Image.new("RGB", (1024, 1024), PREVIEW_BG)
    pad = int(1024 * 0.12)
    thumb = resized(1024 - pad * 2)
    preview.paste(thumb, (pad, pad), thumb)
    save(preview, ASSETS / "wisp_icon_preview.png")
    save(fg.copy(), ASSETS / "wisp_icon_foreground.png")
    save(flatten(master, 1024, IOS_BG), ASSETS / "wisp_icon_legacy_1024.png")

    # --- Windows：多帧 ico ---
    master.save(WIN_RES / "app_icon.ico", format="ICO",
                sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
                       (64, 64), (128, 128), (256, 256)])
    _written.append(WIN_RES / "app_icon.ico")

    # --- macOS ---
    for n in (16, 32, 64, 128, 256, 512, 1024):
        save(resized(n), MAC_ICONS / f"app_icon_{n}.png")

    # --- iOS：文件名自带 base@scale，四角填白 ---
    for path in sorted(IOS_ICONS.glob("Icon-App-*.png")):
        m = re.match(r"Icon-App-([\d.]+)x[\d.]+@(\d)x\.png", path.name)
        if not m:
            continue
        n = int(round(float(m.group(1)) * int(m.group(2))))
        save(flatten(resized(n), n, IOS_BG), path)

    # --- Android：legacy mipmap 用主图，adaptive foreground 用前景图 ---
    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for dpi, scale in densities.items():
        save(resized(int(48 * scale)), ANDROID_RES / f"mipmap-{dpi}" / "ic_launcher.png")
        save(resized(int(108 * scale), FOREGROUND),
             ANDROID_RES / f"drawable-{dpi}" / "ic_launcher_foreground.png")

    # --- Web ---
    save(resized(16), WEB / "favicon.png")
    for n in (192, 512):
        img = resized(n)
        save(img, WEB / "icons" / f"Icon-{n}.png")
        save(img.copy(), WEB / "icons" / f"Icon-maskable-{n}.png")

    for path in _written:
        assert path.is_file() and path.stat().st_size > 0, f"写入失败：{path}"
    print(f"方案 C 青绿图标已分发到 {len(_written)} 个平台资产文件")
    print("矢量源：assets/icon/wisp_icon.svg（改图形后需重新光栅化两张 1024 源图）")


if __name__ == "__main__":
    main()
