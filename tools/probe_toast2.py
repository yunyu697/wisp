"""通知卡片物理分辨率诊断（DPI aware，抓全尺寸 744x300）。"""

import ctypes
import ctypes.wintypes as wt
import struct

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))


def main():
    hwnd = user32.FindWindowExW(None, None, 'WISP_TOAST', None)
    if not hwnd:
        print('toast: 不存在')
        return
    r = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    w, h = r.right - r.left, r.bottom - r.top
    vis = bool(user32.IsWindowVisible(hwnd))
    print(f'toast visible={vis} rect=({r.left},{r.top}) {w}x{h}')
    if not vis:
        return
    hdc_w = user32.GetDC(hwnd)
    mdc = gdi32.CreateCompatibleDC(hdc_w)
    bmi = ctypes.create_string_buffer(40)
    bmi.raw = struct.pack('IiiHHIIiiII', 40, w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
    bits = ctypes.c_void_p()
    sec = gdi32.CreateDIBSection(mdc, bmi, 0, ctypes.byref(bits), None, 0)
    old = gdi32.SelectObject(mdc, sec)
    user32.PrintWindow(hwnd, mdc, 2)
    buf = (ctypes.c_ubyte * (w * h * 4)).from_address(bits.value)
    stride = w * 4

    def avg(x0, y0, x1, y1):
        sr = sg = sb = n = 0
        for y in range(y0, y1):
            for x in range(x0, x1):
                o = y * stride + x * 4
                sb += buf[o]
                sg += buf[o + 1]
                sr += buf[o + 2]
                n += 1
        return (sr // n, sg // n, sb // n)

    def brand_px(x0, y0, x1, y1):
        n = 0
        for y in range(y0, y1):
            for x in range(x0, x1):
                o = y * stride + x * 4
                b, g_, rr = buf[o], buf[o + 1], buf[o + 2]
                if b > 200 and rr < 150 and b - rr > 90:
                    n += 1
        return n

    # 逻辑布局 *2：图标(64,68)-(152,156) 主按钮(438,180)-(680,240) 副(180,180)-(422,240)
    print(f'图标区 avg={avg(70, 74, 146, 150)} brand={brand_px(64, 68, 152, 156)}')
    print(f'主按钮区 avg={avg(450, 190, 670, 230)} brand={brand_px(438, 180, 680, 240)}')
    print(f'副按钮区 avg={avg(190, 190, 410, 230)} brand={brand_px(180, 180, 422, 240)}')
    print(f'进度条区 avg={avg(200, 200, 660, 214)} brand={brand_px(180, 196, 680, 214)}')

    # 模式判定
    p = brand_px(438, 180, 680, 240)
    if p > 3000:
        print('=> ask 模式（主按钮品牌蓝）')
    elif brand_px(180, 196, 680, 214) > 300:
        print('=> progress 模式（进度条蓝）')
    else:
        print('=> done 模式或其他')
    gdi32.SelectObject(mdc, old)
    gdi32.DeleteObject(sec)
    gdi32.DeleteDC(mdc)
    user32.ReleaseDC(hwnd, hdc_w)


if __name__ == '__main__':
    main()
