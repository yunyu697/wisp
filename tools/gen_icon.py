"""生成苹果风格的 Wisp 图标与悬浮球贴图。

设计（第三版，2026-10-30 重做）：
  旧图标是白底蓝色纸飞机 —— 和 Telegram 撞脸，用户明确要求换掉。
  新构图：一张**圆角文件卡片**（青绿渐变，带折角与两条白色文字线），
  一缕**白色流动带**从卡片下沿绕上来，末端缀一颗**珊瑚色圆点**。
  读法："文件正在被一缕轻烟送走" —— 贴合 Wisp（一缕轻烟）+ 近场传文件，
  且没有任何三角/箭头轮廓，不会再看成纸飞机。

  配色严格三种：浅色背景（暖白）+ 青绿 + 珊瑚。
  青绿 = 传输/信任，珊瑚 = 正在移动的那一份数据。

产物（路径与旧版一致，替换后无需改工程配置）：
  assets/icon/wisp_icon_1024.png         squircle 主图标（RGBA，四角透明）
  assets/icon/wisp_icon_foreground.png   Android 自适应前景（glyph 居中留边）
  assets/icon/wisp_icon_preview.png      预览图（放在浅色底上看真实效果）
  windows/runner/resources/ball.png      悬浮球贴图（圆形 + 投影，带 alpha）
  windows/runner/resources/app_icon.ico  多尺寸 ico（16-256）

用法：
  python tools/gen_icon.py
依赖：Pillow（无 numpy）。
"""

from __future__ import annotations

import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets", "icon")
RESOURCES = os.path.join(ROOT, "windows", "runner", "resources")

# --- 调色板：只有三种（背景 / 青绿 / 珊瑚） ---
BG_TOP = (253, 252, 249)
BG_BOTTOM = (233, 229, 220)
TEAL_LIGHT = (58, 200, 203)   # 3AC8CB
TEAL_DARK = (14, 124, 134)    # 0E7C86
CORAL = (255, 122, 89)        # FF7A59
WHITE = (255, 255, 255)

SUPER_N = 5.0  # 苹果 squircle 指数
SS = 4         # 超采样倍率


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def squircle_mask(size: int) -> Image.Image:
    """苹果 squircle 掩膜（超采样后缩放，边缘平滑）。"""
    big = size * SS
    r = big / 2.0
    pts = []
    steps = 1440
    for i in range(steps):
        t = i / steps * 2 * math.pi
        c, s = math.cos(t), math.sin(t)
        x = r + r * math.copysign(abs(c) ** (2 / SUPER_N), c)
        y = r + r * math.copysign(abs(s) ** (2 / SUPER_N), s)
        pts.append((x, y))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def vertical_gradient(size: int, top, bottom) -> Image.Image:
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        d.line([(0, y), (size, y)], fill=lerp(top, bottom, y / (size - 1)))
    return img


def diagonal_gradient(size: int, a, b) -> Image.Image:
    """45° 对角渐变：用两张半程渐变叠加取平均，避免 numpy。"""
    half = Image.new("RGB", (size, 1))
    px = half.load()
    for x in range(size):
        px[x, 0] = lerp(a, b, x / (size - 1))
    gx = half.resize((size, size)).load()
    gy = half.resize((size, size)).rotate(90).load()
    out = Image.new("RGB", (size, size))
    o = out.load()
    for y in range(size):
        for x in range(size):
            pa, pb = gx[x, y], gy[x, y]
            o[x, y] = tuple((pa[i] + pb[i]) // 2 for i in range(3))
    return out


def rounded_rect(size, radius, fill) -> Image.Image:
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        [0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=fill)
    return layer


def bezier(p0, p1, p2, p3, t):
    mt = 1 - t
    x = (mt ** 3) * p0[0] + 3 * (mt ** 2) * t * p1[0] + 3 * mt * (t ** 2) * p2[0] + (t ** 3) * p3[0]
    y = (mt ** 3) * p0[1] + 3 * (mt ** 2) * t * p1[1] + 3 * mt * (t ** 2) * p2[1] + (t ** 3) * p3[1]
    return x, y


def draw_glyph(size: int, with_shadow: bool = True) -> Image.Image:
    """只画图案（两张错开的卡片 + 珊瑚圆点），背景透明。

    构图取"两台设备之间传一份文件"：前面一张实心青绿文件卡（带白色文字线），
    后面一张同尺寸的描边卡（另一台设备），两卡交错处点一颗珊瑚圆点
    —— 那颗点就是"正在移动的数据"。没有三角/箭头，不会被认成纸飞机。

    with_shadow=False 用于悬浮球：圆盘本身已是浅底，再叠一层投影会显脏。
    """
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    side = int(size * 0.440)
    radius = int(side * 0.235)

    # --- 后面那张卡：只描边，表示"另一台设备" ---
    back = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    bd = ImageDraw.Draw(back)
    stroke = max(2, int(side * 0.048))
    bd.rounded_rectangle([stroke // 2, stroke // 2, side - 1 - stroke // 2,
                          side - 1 - stroke // 2],
                         radius=radius, outline=TEAL_DARK + (110,),
                         width=stroke)
    back = back.rotate(9, resample=Image.BICUBIC, expand=True)
    layer.alpha_composite(back, (int(size * 0.558) - back.width // 2,
                                 int(size * 0.383) - back.height // 2))

    # --- 前面那张卡：实心渐变 + 白色文字线 ---
    front = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    grad = diagonal_gradient(side, TEAL_LIGHT, TEAL_DARK)
    front.paste(grad, (0, 0))
    front.putalpha(rounded_rect((side, side), radius, (255, 255, 255, 255)).getchannel("A"))

    # 顶部一层极淡的高光，让卡片有厚度。
    # 用竖直渐变而不是椭圆：椭圆会在卡片上留下一条可见的弧形接缝。
    alpha_col = Image.new("L", (1, side))
    ac = alpha_col.load()
    for y in range(side):
        t = y / (side * 0.55)
        ac[0, y] = max(0, int(46 * (1 - min(1.0, t)) ** 2))
    gloss = Image.new("RGBA", (side, side), (255, 255, 255, 255))
    gloss.putalpha(alpha_col.resize((side, side)))
    gloss.putalpha(Image.composite(gloss.getchannel("A"),
                                   Image.new("L", (side, side), 0),
                                   front.getchannel("A")))
    front = Image.alpha_composite(front, gloss)

    # 两条白色文字线。
    lines = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lines)
    lx = int(side * 0.21)
    lw = int(side * 0.58)
    lh = max(3, int(side * 0.056))
    for i, ratio in enumerate((1.0, 0.66)):
        ly = int(side * (0.52 + i * 0.16))
        ld.rounded_rectangle([lx, ly, lx + int(lw * ratio), ly + lh],
                             radius=lh // 2, fill=(255, 255, 255, 240))
    lines.putalpha(Image.composite(lines.getchannel("A"),
                                   Image.new("L", (side, side), 0),
                                   front.getchannel("A")))
    front = Image.alpha_composite(front, lines)

    rotated = front.rotate(-7, resample=Image.BICUBIC, expand=True)
    fx = int(size * 0.448) - rotated.width // 2
    fy = int(size * 0.512) - rotated.height // 2

    # 投影：同色系柔光，浅底上比灰黑干净。
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sil = Image.new("RGBA", rotated.size, (0, 0, 0, 0))
    sil.paste((16, 88, 96, 96), (0, 0), rotated.getchannel("A"))
    shadow.paste(sil, (fx + int(size * 0.010), fy + int(size * 0.026)), sil)
    shadow = shadow.filter(ImageFilter.GaussianBlur(size * 0.020))
    if with_shadow:
        layer = Image.alpha_composite(layer, shadow)
    layer.alpha_composite(rotated, (fx, fy))

    # --- 珊瑚圆点：两卡交错处，"正在移动的那份数据" ---
    dr = size * 0.043
    dx, dy = size * 0.641, size * 0.349
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        [dx - dr * 1.7, dy - dr * 1.7, dx + dr * 1.7, dy + dr * 1.7],
        fill=CORAL + (56,))
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.014))
    layer = Image.alpha_composite(layer, glow)
    dot = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(dot).ellipse([dx - dr, dy - dr, dx + dr, dy + dr],
                                fill=CORAL + (255,))
    # 圆点上的小高光，让它是"球"而不是"圆片"。
    hi = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(hi).ellipse(
        [dx - dr * 0.45, dy - dr * 0.55, dx + dr * 0.15, dy - dr * 0.05],
        fill=(255, 255, 255, 150))
    hi = hi.filter(ImageFilter.GaussianBlur(size * 0.006))
    dot = Image.alpha_composite(dot, hi)
    layer = Image.alpha_composite(layer, dot)

    return layer


def make_icon(size: int = 1024) -> Image.Image:
    bg = vertical_gradient(size, BG_TOP, BG_BOTTOM).convert("RGBA")
    # 顶部柔光，苹果图标常见的一层薄高光。
    gloss = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gloss)
    gd.ellipse([-size * 0.25, -size * 0.62, size * 1.25, size * 0.42],
               fill=(255, 255, 255, 120))
    gloss = gloss.filter(ImageFilter.GaussianBlur(size * 0.05))
    bg = Image.alpha_composite(bg, gloss)

    icon = Image.alpha_composite(bg, draw_glyph(size))
    icon.putalpha(squircle_mask(size))
    return icon


def make_foreground(size: int = 1024) -> Image.Image:
    """Android 自适应图标前景：glyph 缩到 62% 居中（安全区内）。"""
    inner = int(size * 0.62)
    glyph = draw_glyph(inner)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(glyph, ((size - inner) // 2, (size - inner) // 2))
    return out


def make_preview(icon: Image.Image, size: int = 1024) -> Image.Image:
    """浅灰底上的预览（模拟桌面观感，四角留白）。"""
    pad = int(size * 0.12)
    canvas = Image.new("RGB", (size, size), (245, 246, 249))
    thumb = icon.resize((size - pad * 2, size - pad * 2), Image.LANCZOS)
    canvas.paste(thumb, (pad, pad), thumb)
    return canvas


def make_ball(size: int = 640) -> Image.Image:
    """悬浮球：纯白圆盘 + 一圈柔和投影 + 同一套 glyph。

    视觉上只允许有**一圈**轮廓感（外投影）。旧版在圆盘内叠了一块
    高光椭圆，它的模糊边缘在浅底上形成第二圈灰环，被反馈
    "悬浮球有两个边框"——已去掉，中心提亮改用无硬边的径向渐变。
    """
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pad = int(size * 0.10)
    d = size - pad * 2

    # 外投影：往下偏一点、更大更柔、更淡，读作"悬浮的影子"而不是描边。
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(
        [pad, pad + int(size * 0.035), pad + d, pad + d + int(size * 0.035)],
        fill=(18, 60, 90, 52))
    shadow = shadow.filter(ImageFilter.GaussianBlur(size * 0.040))
    canvas = Image.alpha_composite(canvas, shadow)

    # 圆盘：纯白。中心不做分块高光，改用整面径向渐变（边缘 alpha 归零，
    # 不产生任何可见的分界线）。
    disc = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(disc).ellipse([pad, pad, pad + d, pad + d],
                                 fill=(255, 255, 255, 255))
    grad = Image.radial_gradient("L").resize((d, d), Image.LANCZOS)
    # 径向渐变：中心 0 → 边缘 255。反转并压低强度（最多 26/255 的白），
    # 让中心比边缘亮一点点，但没有可察觉的"环"。
    lift_mask = grad.point(lambda v: int((255 - v) * 26 / 255 * 1.4))
    lift = Image.new("RGBA", (d, d), (255, 255, 255, 0))
    lift.putalpha(lift_mask)
    disc.alpha_composite(lift, (pad, pad))
    canvas = Image.alpha_composite(canvas, disc)

    glyph_size = int(d * 0.72)
    glyph = draw_glyph(glyph_size, with_shadow=False)
    canvas.alpha_composite(glyph, (pad + (d - glyph_size) // 2,
                                   pad + (d - glyph_size) // 2))
    return canvas


def write_ico(src: Image.Image, path: str) -> None:
    src.save(path, format="ICO",
             sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64),
                    (128, 128), (256, 256)])


def main() -> None:
    os.makedirs(ASSETS, exist_ok=True)
    icon = make_icon(1024)
    icon.save(os.path.join(ASSETS, "wisp_icon_1024.png"))
    make_preview(icon).save(os.path.join(ASSETS, "wisp_icon_preview.png"))
    make_foreground(1024).save(os.path.join(ASSETS, "wisp_icon_foreground.png"))
    make_ball(640).save(os.path.join(RESOURCES, "ball.png"))
    write_ico(icon, os.path.join(RESOURCES, "app_icon.ico"))

    # 自检：图案必须有颜色（不能是白底白图），且三种主色都在。
    px = icon.convert("RGB").load()
    w, h = icon.size
    teal = coral = 0
    for y in range(0, h, 7):
        for x in range(0, w, 7):
            r, g, b = px[x, y]
            if b > r and g > r + 40:
                teal += 1
            elif r > 180 and g < 160 and b < 140:
                coral += 1
    print(f"teal px={teal} coral px={coral}")
    assert teal > 200, "青绿主体缺失"
    assert coral > 20, "珊瑚圆点缺失"
    print("图标已生成：1024 / preview / foreground / ball / ico(7 档)")


if __name__ == "__main__":
    main()
