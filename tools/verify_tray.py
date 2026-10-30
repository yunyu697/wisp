"""验证 Windows 端的窗口行为：最小尺寸、关闭到托盘、托盘恢复。

直接给窗口发消息，模拟用户操作，比截图可靠。

用法：python verify_tray.py <exe 路径>
"""

import ctypes
import ctypes.wintypes as wt
import subprocess
import sys
import time

user32 = ctypes.windll.user32

WM_CLOSE = 0x0010
WM_GETMINMAXINFO = 0x0024
WM_APP = 0x8000
WM_LBUTTONDBLCLK = 0x0203
WM_RBUTTONUP = 0x0205

kTrayMessage = WM_APP + 1


class MINMAXINFO(ctypes.Structure):
    _fields_ = [
        ("ptReserved", wt.POINT),
        ("ptMaxSize", wt.POINT),
        ("ptMaxPosition", wt.POINT),
        ("ptMinTrackSize", wt.POINT),
        ("ptMaxTrackSize", wt.POINT),
    ]


def find_window(title="Wisp"):
    handles = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def callback(hwnd, _):
        length = user32.GetWindowTextLengthW(hwnd)
        if length:
            buffer = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buffer, length + 1)
            if buffer.value == title:
                handles.append(hwnd)
        return True

    user32.EnumWindows(callback, 0)
    return handles[0] if handles else None


def is_visible(hwnd):
    return bool(user32.IsWindowVisible(hwnd))


def main():
    exe = sys.argv[1]
    proc = subprocess.Popen([exe])
    print(f"[test] 已启动 {exe} (pid={proc.pid})")

    hwnd = None
    for _ in range(40):
        time.sleep(0.5)
        hwnd = find_window()
        if hwnd:
            break

    if not hwnd:
        print("[test] 失败：没有找到窗口")
        proc.kill()
        return 1

    print(f"[test] 找到窗口 hwnd={hwnd}")

    # 等首帧渲染完再测。debug 模式下首帧要编译 shader，可能要好几秒，
    # 太早发 WM_CLOSE 会撞上 Flutter 的 show 回调。
    print("[test] 等待首帧渲染完成...")
    time.sleep(12)

    # 1. 最小尺寸限制
    info = MINMAXINFO()
    user32.SendMessageW(hwnd, WM_GETMINMAXINFO, 0, ctypes.byref(info))
    print(f"[test] 最小尺寸 = {info.ptMinTrackSize.x} x {info.ptMinTrackSize.y} 物理像素")

    # 2. 点关闭按钮 → 应该隐藏到托盘而不是退出
    user32.PostMessageW(hwnd, WM_CLOSE, 0, 0)
    time.sleep(2.0)
    still_running = proc.poll() is None
    visible = is_visible(hwnd)
    print(f"[test] 关闭后：进程存活={still_running}，窗口可见={visible}")
    if still_running and not visible:
        print("[test] 通过：窗口已隐藏，进程仍在后台运行")
    else:
        print("[test] 失败：关闭后没有正确隐藏到托盘")

    # 3. 模拟双击托盘图标 → 窗口应该恢复
    user32.SendMessageW(hwnd, kTrayMessage, 0, WM_LBUTTONDBLCLK)
    time.sleep(1.0)
    restored = is_visible(hwnd)
    print(f"[test] 托盘双击后窗口可见={restored}")
    if restored:
        print("[test] 通过：托盘可以恢复窗口")
    else:
        print("[test] 失败：托盘没能恢复窗口")

    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
