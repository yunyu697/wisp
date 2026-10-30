"""悬浮球位置记忆端到端验证。

流程: 启动(默认右下角) → 模拟拖到左边缘 → 校验吸附+落盘 → 由外层重启复验。
"""

import ctypes
import ctypes.wintypes as wt
import json
import os
import struct
import time

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))


def rect_of(hwnd):
    r = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    return (r.left, r.top, r.right, r.bottom)


def drag(hwnd, from_pt, to_pt):
    """处理器用 GetCursorPos 计算位移，因此必须移动真实光标。"""
    pt = wt.POINT()
    user32.GetCursorPos(ctypes.byref(pt))
    orig = (pt.x, pt.y)

    def lp(p):
        return (p[1] << 16) | (p[0] & 0xFFFF)

    user32.SetCursorPos(*from_pt)
    time.sleep(0.05)
    user32.PostMessageW(hwnd, 0x201, 1, lp(from_pt))  # LBUTTONDOWN
    time.sleep(0.05)
    steps = 8
    for i in range(1, steps + 1):
        x = from_pt[0] + (to_pt[0] - from_pt[0]) * i // steps
        y = from_pt[1] + (to_pt[1] - from_pt[1]) * i // steps
        user32.SetCursorPos(x, y)
        user32.PostMessageW(hwnd, 0x200, 1, lp((x, y)))  # MOUSEMOVE
        time.sleep(0.03)
    user32.PostMessageW(hwnd, 0x202, 0, lp(to_pt))  # LBUTTONUP
    time.sleep(1.2)  # 等吸附动画与 Dart 落盘
    user32.SetCursorPos(*orig)  # 还原光标


def prefs_ball():
    p = os.path.expandvars(r'%APPDATA%\app.wisp\wisp\shared_preferences.json')
    d = json.load(open(p, encoding='utf-8'))
    s = json.loads(d['flutter.wisp.settings.v1'])
    return {k: s.get(k) for k in ('ballPosX', 'ballPosY', 'ballSnapped', 'ballEdge')}


def main():
    hwnd = user32.FindWindowExW(None, None, 'WISP_FLOAT_BALL', None)
    if not hwnd:
        print('ball 不存在')
        return
    r = rect_of(hwnd)
    print(f'球初始 rect={r}')
    cx, cy = (r[0] + r[2]) // 2, (r[1] + r[3]) // 2

    # 拖到主屏左边缘中部
    work = wt.RECT()
    user32.SystemParametersInfoW(0x0030, 0, ctypes.byref(work), 0)  # SPI_GETWORKAREA
    target = (work.left + 40, (work.top + work.bottom) // 2)
    drag(hwnd, (cx, cy), target)

    hwnd2 = user32.FindWindowExW(None, None, 'WISP_FLOAT_BALL', None)
    r2 = rect_of(hwnd2)
    print(f'拖动后 rect={r2}')
    print('prefs:', prefs_ball())


if __name__ == '__main__':
    main()
