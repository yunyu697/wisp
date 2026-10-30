"""无 Pillow 版窗口截图：PrintWindow + 手写 PNG。

当前环境的 Python 里已经没有 Pillow（`probe_shot.py` 因此不可用），
这个脚本只依赖 ctypes / zlib / struct，用途与它完全一致。

用法:
  python tools/probe_shot_nopil.py class WISP_TOAST toast.png
  python tools/probe_shot_nopil.py class FLUTTER_RUNNER_WIN32_WINDOW main.png
  python tools/probe_shot_nopil.py title LocalSend ls.png
"""

import ctypes
import ctypes.wintypes as wt
import struct
import sys
import zlib

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))


def png_write(path, width, height, rows):
    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    raw = b''.join(b'\x00' + row for row in rows)
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', ihdr))
        f.write(chunk(b'IDAT', zlib.compress(raw, 6)))
        f.write(chunk(b'IEND', b''))


def main():
    mode, value, out = sys.argv[1], sys.argv[2], sys.argv[3]
    if mode == 'class':
        hwnd = user32.FindWindowW(value, None)
    else:
        hwnd = user32.FindWindowW(None, value)
    if not hwnd:
        print('window not found')
        return 1
    r = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    w, h = r.right - r.left, r.bottom - r.top
    print('hwnd=%s rect=%dx%d' % (hwnd, w, h))

    hdc = user32.GetDC(hwnd)
    mdc = gdi32.CreateCompatibleDC(hdc)
    bmi = ctypes.create_string_buffer(40)
    bmi.raw = struct.pack('IiiHHIIiiII', 40, w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
    bits = ctypes.c_void_p()
    sec = gdi32.CreateDIBSection(mdc, bmi, 0, ctypes.byref(bits), None, 0)
    gdi32.SelectObject(mdc, sec)
    user32.PrintWindow(hwnd, mdc, 2)

    # 必须先把像素拷出来再 DeleteObject。
    buf = (ctypes.c_ubyte * (w * h * 4)).from_address(bits.value)
    data = bytes(buf)
    gdi32.DeleteObject(sec)
    gdi32.DeleteDC(mdc)
    user32.ReleaseDC(hwnd, hdc)

    rows = []
    for y in range(h):
        row = bytearray()
        base = y * w * 4
        for x in range(w):
            i = base + x * 4
            b, g, rr, a = data[i], data[i + 1], data[i + 2], data[i + 3]
            # GDI 的 DIB 是 BGRA，PNG 要 RGBA
            row += bytes((rr, g, b, a))
        rows.append(bytes(row))
    png_write(out, w, h, rows)
    print('saved', out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
