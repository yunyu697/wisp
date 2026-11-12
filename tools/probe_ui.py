"""Wisp 桌面 UI 验证探针（无第三方依赖，纯 ctypes）。

能力：
  python tools/probe_ui.py windows   列出 Wisp 相关窗口（主窗口/桌面通知卡）
  python tools/probe_ui.py shot      截取主窗口画面并输出平均亮度（判断是否黑屏）
"""

import ctypes
import ctypes.wintypes as wt
import struct
import sys

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32

WM_GETICON = 0x7F

CLASSES = {
    'main': 'FLUTTER_RUNNER_WIN32_WINDOW',
    'toast': 'WISP_TOAST',
}


def find_by_class(cls: str):
    return user32.FindWindowExW(None, None, cls, None)


def window_rect(hwnd):
    rect = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    return (rect.left, rect.top, rect.right, rect.bottom)


def visible(hwnd) -> bool:
    return bool(user32.IsWindowVisible(hwnd))


def avg_brightness(hwnd) -> float:
    """PrintWindow 截图后计算平均亮度（0-255）。"""
    left, top, right, bottom = window_rect(hwnd)
    w, h = right - left, bottom - top
    if w <= 0 or h <= 0:
        return -1
    hdc_window = user32.GetDC(hwnd)
    hdc_mem = gdi32.CreateCompatibleDC(hdc_window)
    bmi = ctypes.create_string_buffer(40)
    ctypes.memset(bmi, 0, 40)
    struct_fmt = 'IiiHHIIiiII'
    (
        bi_size, bi_width, bi_height, bi_planes, bi_bit_count, bi_compression,
        bi_size_image, bi_x, bi_y, bi_colors, bi_important,
    ) = (40, w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
    ctypes.memmove(bmi, struct.pack(struct_fmt, bi_size, bi_width, bi_height,
                                    bi_planes, bi_bit_count, bi_compression,
                                    bi_size_image, bi_x, bi_y, bi_colors,
                                    bi_important), 40)
    # DIB section 便于读回像素。
    bits = ctypes.c_void_p()
    section = gdi32.CreateDIBSection(hdc_mem, bmi, 0, ctypes.byref(bits), None, 0)
    if not section:
        return -1
    old = gdi32.SelectObject(hdc_mem, section)
    # PW_RENDERFULLCONTENT=2 能抓到 DirectComposition 内容。
    user32.PrintWindow(hwnd, hdc_mem, 2)
    buf = (ctypes.c_ubyte * (w * h * 4)).from_address(bits.value)
    total = 0
    count = 0
    stride = w * 4
    for y in range(0, h, 6):
        for x in range(0, w, 6):
            off = y * stride + x * 4
            b, g, r = buf[off], buf[off + 1], buf[off + 2]
            total += (r * 30 + g * 59 + b * 11) // 100
            count += 1
    gdi32.SelectObject(hdc_mem, old)
    gdi32.DeleteObject(section)
    gdi32.DeleteDC(hdc_mem)
    user32.ReleaseDC(hwnd, hdc_window)
    return total / count if count else -1


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'windows'
    if cmd == 'windows':
        for name, cls in CLASSES.items():
            hwnd = find_by_class(cls)
            if not hwnd:
                print(f'{name}: 不存在')
                continue
            state = '可见' if visible(hwnd) else '隐藏'
            print(f'{name}: hwnd=0x{hwnd:X} {state} rect={window_rect(hwnd)}')
    elif cmd == 'shot':
        hwnd = find_by_class(CLASSES['main'])
        if not hwnd:
            print('主窗口不存在')
            return
        print(f'主窗口 rect={window_rect(hwnd)} 平均亮度={avg_brightness(hwnd):.1f}')
    else:
        print(__doc__)


if __name__ == '__main__':
    main()
