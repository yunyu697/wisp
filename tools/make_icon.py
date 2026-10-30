"""Render the Wisp app icon as clean vectors -> PNG (no watermark, crisp edges)."""
import math
from PIL import Image, ImageDraw

S = 1024
SS = 4
OUT = r"C:/Users/Tyler Zhang/WorkBuddy AI/2026-10-27-20-51-53/wisp/assets/icon"

TOP_LEFT = (122, 92, 255)    # #7A5CFF
BOTTOM_RIGHT = (38, 148, 255)  # #2694FF
DEEP = (74, 74, 240)         # #4A4AF0


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        row = y / size
        for x in range(size):
            t = x / size * 0.5 + row * 0.5
            base = lerp(TOP_LEFT, BOTTOM_RIGHT, t)
            # deepen the bottom edge a touch for depth
            base = lerp(base, DEEP, max(0.0, (row - 0.72) / 0.28) ** 2 * 0.55)
            dx, dy = x / size - 0.26, row - 0.16
            d = math.sqrt(dx * dx + dy * dy)
            glow = max(0.0, 1.0 - d / 0.62) ** 2.6 * 0.26
            px[x, y] = tuple(min(255, round(c + (255 - c) * glow)) for c in base)
    return img


def draw_mark(size):
    """A dot with two arcs opening right: a whisper reaching a nearby device."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = size / 1000.0
    cx = cy = 500 * k
    white = (255, 255, 255, 255)

    r_dot = 118 * k
    d.ellipse([cx - r_dot, cy - r_dot, cx + r_dot, cy + r_dot], fill=white)

    for radius, width, span in ((238, 66, 57), (352, 56, 57)):
        rr, ww = radius * k, width * k
        box = [cx - rr, cy - rr, cx + rr, cy + rr]
        d.arc(box, start=-span, end=span, fill=white, width=round(ww))
        # PIL strokes inward from the bounding box, so the stroke centre sits at r - w/2
        rc = rr - ww / 2
        for ang in (-span, span):
            a = math.radians(ang)
            px_, py_ = cx + rc * math.cos(a), cy + rc * math.sin(a)
            d.ellipse([px_ - ww / 2, py_ - ww / 2, px_ + ww / 2, py_ + ww / 2], fill=white)
    return img


def squircle_mask(size, radius_ratio=0.2237):
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size * 4 - 1, size * 4 - 1], radius=round(size * 4 * radius_ratio), fill=255)
    return mask.resize((size, size), Image.LANCZOS)


# --- mark: render large, trim, then centre at a fixed optical size -----------
raw = draw_mark(S * SS)
bbox = raw.getbbox()
mark = raw.crop(bbox)
target_h = round(S * 0.60)
target_w = round(mark.width * target_h / mark.height)
mark = mark.resize((target_w, target_h), Image.LANCZOS)

bg = gradient(S).convert("RGBA")
icon = bg.copy()
icon.alpha_composite(mark, ((S - target_w) // 2, (S - target_h) // 2))
icon.save(f"{OUT}/wisp_icon_1024.png")

preview = Image.new("RGBA", (S, S), (0, 0, 0, 0))
preview.paste(icon, (0, 0), squircle_mask(S))
preview.save(f"{OUT}/wisp_icon_preview.png")

fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
fg.alpha_composite(mark, ((S - target_w) // 2, (S - target_h) // 2))
fg.save(f"{OUT}/wisp_icon_foreground.png")

print("mark bbox", bbox, "->", target_w, target_h)
