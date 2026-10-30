"""把任意窗口的 PrintWindow 结果存成 PNG（用于肉眼核对界面内容）。

用法：
  python tools/probe_shot.py class FLUTTER_RUNNER_WIN32_WINDOW out.png
  python tools/probe_shot.py title LocalSend out.png

要点（踩过的坑）：
  * 必须先把进程设为 Per-Monitor DPI aware(-4)，否则 200% 缩放下
    GetWindowRect 拿到的是虚拟化尺寸，PrintWindow 会按真实尺寸渲染后被裁掉。
  * PW_RENDERFULLCONTENT=2 才能抓到 Flutter(Impeller/DirectComposition) 的画面。
  * DIB 像素必须在 DeleteObject 之前读完。
"""

import ctypes
import ctypes.wintypes as wt
import struct
import sys

from PIL import Image

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32


def set_dpi_aware() -> None:
    try:
        user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    except Exception:
        user32.SetProcessDPIAware()


def find_window(mode: str, needle: str) -> int:
    if mode == 'class':
        return user32.FindWindowExW(None, None, needle, None)
    if mode == 'pid':
        # 官方 LocalSend 与 Wisp 都是 Flutter，窗口类名相同，
        # 只能按进程 PID 精确取窗口。
        want = int(needle)
        hits = []

        @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
        def cb_pid(hwnd, _):
            pid = wt.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if pid.value == want and user32.IsWindowVisible(hwnd):
                n = user32.GetWindowTextLengthW(hwnd)
                buf = ctypes.create_unicode_buffer(n + 1)
                user32.GetWindowTextW(hwnd, buf, n + 1)
                # 跳过隐藏的 tooltip/托盘辅助窗口
                if buf.value:
                    hits.append(hwnd)
                    return False
            return True

        user32.EnumWindows(cb_pid, 0)
        return hits[0] if hits else 0
    # title 模式：枚举顶层窗口，找标题包含 needle 的第一个可见窗口
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        n = user32.GetWindowTextLengthW(hwnd)
        if n == 0:
            return True
        buf = ctypes.create_unicode_buffer(n + 1)
        user32.GetWindowTextW(hwnd, buf, n + 1)
        if needle.lower() in buf.value.lower():
            found.append(hwnd)
            return False
        return True

    user32.EnumWindows(cb, 0)
    return found[0] if found else 0


def grab(hwnd: int) -> Image.Image:
    rect = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w, h = rect.right - rect.left, rect.bottom - rect.top
    hdc_window = user32.GetDC(hwnd)
    hdc_mem = gdi32.CreateCompatibleDC(hdc_window)
    bmi = ctypes.create_string_buffer(40)
    ctypes.memset(bmi, 0, 40)
    fmt = 'IiiHHIIiiII'
    ctypes.memmove(
        bmi,
        struct.pack(fmt, 40, w, -h, 1, 32, 0, 0, 0, 0, 0, 0),
        40,
    )
    bits = ctypes.c_void_p()
    section = gdi32.CreateDIBSection(hdc_mem, bmi, 0, ctypes.byref(bits), None, 0)
    old = gdi32.SelectObject(hdc_mem, section)
    user32.PrintWindow(hwnd, hdc_mem, 2)
    raw = ctypes.string_at(bits.value, w * h * 4)
    gdi32.SelectObject(hdc_mem, old)
    gdi32.DeleteObject(section)
    gdi32.DeleteDC(hdc_mem)
    user32.ReleaseDC(hwnd, hdc_window)
    # DIB 是 BGRA，转成 RGB
    return Image.frombuffer('RGBA', (w, h), raw, 'raw', 'BGRA', 0, 1).convert('RGB')


def main() -> None:
    if len(sys.argv) < 4:
        print(__doc__)
        return
    set_dpi_aware()
    mode, needle, out = sys.argv[1], sys.argv[2], sys.argv[3]
    hwnd = find_window(mode, needle)
    if not hwnd:
        print(f'未找到窗口（{mode}={needle}）')
        return
    rect = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    img = grab(hwnd)
    img.save(out)
    print(f'hwnd=0x{hwnd:X} rect=({rect.left},{rect.top},{rect.right},{rect.bottom}) '
          f'size={img.size} -> {out}')


if __name__ == '__main__':
    main()
