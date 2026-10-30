"""模拟真实鼠标点击（物理屏幕坐标）。

为什么要真实输入而不是 PostMessage：Flutter/Impeller 的命中测试走的是
系统输入队列，合成的 WM_LBUTTONDOWN 在部分控件上会被忽略。

用法：
  python tools/probe_click.py 180 673
"""

import ctypes
import sys
import time

user32 = ctypes.windll.user32

MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004


def main() -> None:
    if len(sys.argv) < 3:
        print(__doc__)
        return
    x, y = int(sys.argv[1]), int(sys.argv[2])
    user32.SetCursorPos(x, y)
    time.sleep(0.15)
    user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
    time.sleep(0.05)
    user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
    time.sleep(0.4)
    print(f'clicked ({x},{y})')


if __name__ == '__main__':
    main()
