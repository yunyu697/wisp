"""卡片三态严格时序验证：等待 ask 出现 → 点接收 → 追踪到 done。

用法: 先后台启动 probe_send，再运行本脚本。
"""

import ctypes
import ctypes.wintypes as wt
import struct
import time

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))


def find_toast():
    return user32.FindWindowExW(None, None, 'WISP_TOAST', None)


def capture(hwnd):
    r = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    w, h = r.right - r.left, r.bottom - r.top
    hdc_w = user32.GetDC(hwnd)
    mdc = gdi32.CreateCompatibleDC(hdc_w)
    bmi = ctypes.create_string_buffer(40)
    bmi.raw = struct.pack('IiiHHIIiiII', 40, w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
    bits = ctypes.c_void_p()
    sec = gdi32.CreateDIBSection(mdc, bmi, 0, ctypes.byref(bits), None, 0)
    old = gdi32.SelectObject(mdc, sec)
    user32.PrintWindow(hwnd, mdc, 2)
    buf = (ctypes.c_ubyte * (w * h * 4)).from_address(bits.value)
    return buf, w, h, w * 4, sec, mdc, old, hdc_w


def release(sec, mdc, old, hdc_w):
    gdi32.SelectObject(mdc, old)
    gdi32.DeleteObject(sec)
    gdi32.DeleteDC(mdc)
    user32.ReleaseDC(hwnd_dc_holder[0], hdc_w) if False else None
    user32.ReleaseDC(user32.FindWindowExW(None, None, 'WISP_TOAST', None), hdc_w)


def brand_in(buf, stride, x0, y0, x1, y1):
    n = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            o = y * stride + x * 4
            b, r_ = buf[o], buf[o + 2]
            if b > 200 and r_ < 150 and b - r_ > 90:
                n += 1
    return n


def mode_of(hwnd):
    if not hwnd or not user32.IsWindowVisible(hwnd):
        return 'hidden'
    buf, w, h, stride, sec, mdc, old, hdc_w = capture(hwnd)
    try:
        btn = brand_in(buf, stride, 438, 180, 680, 240)      # 主按钮区
        bar = brand_in(buf, stride, 180, 196, 680, 214)      # 进度条区
    finally:
        gdi32.SelectObject(mdc, old)
        gdi32.DeleteObject(sec)
        gdi32.DeleteDC(mdc)
        user32.ReleaseDC(hwnd, hdc_w)
    if btn > 3000:
        return 'ask'
    if bar > 300:
        return 'progress'
    return 'done/other'


def click(hwnd, x, y):
    lp = (y << 16) | x
    user32.PostMessageW(hwnd, 0x201, 1, lp)
    time.sleep(0.06)
    user32.PostMessageW(hwnd, 0x202, 0, lp)


def main():
    print('等待 ask 卡片出现...')
    t0 = time.time()
    hwnd = None
    while time.time() - t0 < 15:
        hwnd = find_toast()
        m = mode_of(hwnd)
        if m == 'ask':
            print(f't={time.time()-t0:.1f}s ask 出现')
            break
        time.sleep(0.3)
    else:
        print('15s 内未出现 ask 卡片，退出')
        return

    click(hwnd, 559, 210)
    print('已点击 接收(559,210)')

    prev = None
    t0 = time.time()
    while time.time() - t0 < 30:
        m = mode_of(find_toast())
        if m != prev:
            print(f't={time.time()-t0:.1f}s -> {m}')
            prev = m
        if m == 'done/other':
            # done 稳定后点「关闭」副按钮
            time.sleep(0.8)
            if mode_of(find_toast()) == 'done/other':
                click(find_toast(), 301, 210)
                print('已点击 关闭(301,210)')
                time.sleep(0.5)
                print(f'关闭后: {mode_of(find_toast())}')
                return
        time.sleep(0.4)
    print('30s 跟踪结束')


if __name__ == '__main__':
    main()
