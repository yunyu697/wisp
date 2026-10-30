"""通知卡片（WISP_TOAST）像素级诊断探针。

用法: python tools/probe_toast.py
输出: 窗口矩形、可见性、色彩分类统计与 6x4 网格采样。
"""

import ctypes
import ctypes.wintypes as wt
import struct

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32


def capture(hwnd):
    """PrintWindow 抓取窗口内容，返回 (w, h, buf, stride, section)。

    section 由调用方负责 DeleteObject——在读完 buf 之前不能释放。
    """
    rect = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w, h = rect.right - rect.left, rect.bottom - rect.top
    if w <= 0 or h <= 0:
        return None
    hdc_window = user32.GetDC(hwnd)
    hdc_mem = gdi32.CreateCompatibleDC(hdc_window)
    bmi = ctypes.create_string_buffer(40)
    struct_fmt = 'IiiHHIIiiII'
    header = struct.pack(struct_fmt, 40, w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
    ctypes.memmove(bmi, header, 40)
    bits = ctypes.c_void_p()
    section = gdi32.CreateDIBSection(hdc_mem, bmi, 0, ctypes.byref(bits), None, 0)
    if not section:
        return None
    old = gdi32.SelectObject(hdc_mem, section)
    user32.PrintWindow(hwnd, hdc_mem, 2)  # PW_RENDERFULLCONTENT
    buf = (ctypes.c_ubyte * (w * h * 4)).from_address(bits.value)
    gdi32.SelectObject(hdc_mem, old)
    gdi32.DeleteDC(hdc_mem)
    user32.ReleaseDC(hwnd, hdc_window)
    return w, h, buf, w * 4, section


def classify(b, g, r, a):
    if a == 0:
        return 'transparent'
    # 品牌蓝按钮（渐变 #7A9CFF..#2B64F5，允许一定容差）
    if b > 200 and r < 150 and g < 190 and b - r > 90:
        return 'brand'
    # 卡片白底（不透明浅色）
    if a > 240 and r > 235 and g > 235 and b > 235:
        return 'white'
    # 半透明阴影/遮罩
    if a < 240:
        return 'shadow'
    # 深色文字
    if r < 110 and g < 110 and b < 130:
        return 'text'
    return 'other'


def main():
    hwnd = user32.FindWindowExW(None, None, 'WISP_TOAST', None)
    if not hwnd:
        print('toast: 不存在')
        return
    rect = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    vis = bool(user32.IsWindowVisible(hwnd))
    print(f'toast hwnd=0x{hwnd:X} visible={vis} '
          f'rect=({rect.left},{rect.top},{rect.right},{rect.bottom})')
    if not vis:
        return
    cap = capture(hwnd)
    if cap is None:
        print('capture failed')
        return
    w, h, buf, stride, section = cap

    # 区域平均色判定模式：主按钮(219,90)-(340,120) 副按钮(90,90)-(211,120)。
    def region_avg(x0, y0, x1, y1):
        sr = sg = sb = n = 0
        for y in range(y0, y1):
            for x in range(x0, x1):
                off = y * stride + x * 4
                sb += buf[off]
                sg += buf[off + 1]
                sr += buf[off + 2]
                n += 1
        return (sr // n, sg // n, sb // n)

    pr = region_avg(230, 95, 330, 115)
    se = region_avg(100, 95, 200, 115)
    print(f'主按钮区平均RGB={pr}  副按钮区平均RGB={se}')
    if pr[2] > 200 and pr[2] - pr[0] > 90:
        print('=> 判定: ask 模式（主按钮为品牌蓝「接收」）')
    elif pr[0] > 200 and pr[1] > 200 and pr[2] > 200:
        print('=> 判定: done 模式（主按钮为灰白「打开目录」）')
    else:
        print('=> 判定: progress 模式或其他（主按钮区非蓝非白）')

    counts = {}
    for y in range(h):
        for x in range(w):
            off = y * stride + x * 4
            b, g_, r, a = buf[off], buf[off + 1], buf[off + 2], buf[off + 3]
            cat = classify(b, g_, r, a)
            counts[cat] = counts.get(cat, 0) + 1
    total = w * h
    print(f'size {w}x{h}, 分类统计:')
    for k in ('brand', 'white', 'text', 'shadow', 'other', 'transparent'):
        n = counts.get(k, 0)
        print(f'  {k:12s} {n:7d}  {100.0 * n / total:5.1f}%')
    gdi32.DeleteObject(section)


if __name__ == '__main__':
    main()
