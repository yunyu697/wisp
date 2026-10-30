// 往 Wisp 主窗口投一次真实的 WM_DROPFILES，验证"拖拽发送"这条链路。
//
// 为什么需要它：Explorer 的拖放要人手拖，自动化无从下手；而 WM_DROPFILES 携带的
// HDROP 就是一个全局内存块（DROPFILES 头 + UTF-16 路径列表），可以自己造一个再
// PostMessage 给窗口。这样能覆盖「原生解析路径 → 通道 → Dart 展开 → 进待发清单」
// 整条链，只剩「Explorer 把消息投给哪个窗口」这一小段靠人工确认。
//
// 用法：
//   dart run tools/probe_drop.dart C:\a.txt D:\某个文件夹
//   dart run tools/probe_drop.dart --hwnd 0x123456 C:\a.txt
//
// 只依赖 dart:ffi，不引 package:ffi / win32——探针不该为项目加依赖。

import 'dart:ffi';
import 'dart:io';

const int _gmemMoveable = 0x0002;
const int _gmemZeroinit = 0x0040;
const int _wmDropfiles = 0x0233;
const int _headerSize = 20; // DROPFILES: pFiles + POINT + fNC + fWide

typedef _AllocNative = IntPtr Function(Uint32, IntPtr);
typedef _AllocDart = int Function(int, int);
typedef _LockNative = Pointer<Uint8> Function(IntPtr);
typedef _LockDart = Pointer<Uint8> Function(int);
typedef _UnlockNative = Int32 Function(IntPtr);
typedef _UnlockDart = int Function(int);
typedef _FindNative = IntPtr Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _FindDart = int Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _PostNative = Int32 Function(IntPtr, Uint32, IntPtr, IntPtr);
typedef _PostDart = int Function(int, int, int, int);
typedef _HeapNative = IntPtr Function();
typedef _HeapDart = int Function();
typedef _HeapAllocNative = Pointer<Uint8> Function(IntPtr, Uint32, IntPtr);
typedef _HeapAllocDart = Pointer<Uint8> Function(int, int, int);

void main(List<String> argv) {
  if (argv.isEmpty) {
    stderr.writeln('用法: dart run tools/probe_drop.dart [--hwnd 0x...] <路径...>');
    exit(2);
  }

  int? hwnd;
  final List<String> paths = <String>[];
  for (int i = 0; i < argv.length; i++) {
    final String arg = argv[i];
    if (arg == '--hwnd' && i + 1 < argv.length) {
      final String raw = argv[++i].replaceFirst('0x', '');
      hwnd = int.parse(raw, radix: 16);
    } else {
      paths.add(arg);
    }
  }
  if (paths.isEmpty) {
    stderr.writeln('至少给一个文件或文件夹路径');
    exit(2);
  }
  for (final String path in paths) {
    if (!FileSystemEntity.isFileSync(path) && !Directory(path).existsSync()) {
      stderr.writeln('路径不存在: $path');
      exit(2);
    }
  }

  final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
  final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');

  final _AllocDart globalAlloc =
      kernel32.lookupFunction<_AllocNative, _AllocDart>('GlobalAlloc');
  final _LockDart globalLock =
      kernel32.lookupFunction<_LockNative, _LockDart>('GlobalLock');
  final _UnlockDart globalUnlock =
      kernel32.lookupFunction<_UnlockNative, _UnlockDart>('GlobalUnlock');
  final _HeapDart getProcessHeap =
      kernel32.lookupFunction<_HeapNative, _HeapDart>('GetProcessHeap');
  final _HeapAllocDart heapAlloc =
      kernel32.lookupFunction<_HeapAllocNative, _HeapAllocDart>('HeapAlloc');
  final _FindDart findWindow =
      user32.lookupFunction<_FindNative, _FindDart>('FindWindowW');
  final _PostDart postMessage =
      user32.lookupFunction<_PostNative, _PostDart>('PostMessageW');

  final int target = hwnd ?? _findMainWindow(findWindow, heapAlloc, getProcessHeap);
  if (target == 0) {
    stderr.writeln('没找到 Wisp 主窗口（FLUTTER_RUNNER_WIN32_WINDOW），应用在运行吗？');
    exit(1);
  }

  final int hMem = _buildHandle(paths, globalAlloc, globalLock, globalUnlock);
  if (hMem == 0) {
    stderr.writeln('构造 HDROP 失败');
    exit(1);
  }

  final int ok = postMessage(target, _wmDropfiles, hMem, 0);
  stdout.writeln('hwnd=0x${target.toRadixString(16)} paths=${paths.length} '
      'posted=${ok != 0}');
  // HDROP 的所有权交给窗口过程（它负责 DragFinish），这里不再释放。
  exit(ok != 0 ? 0 : 1);
}

int _findMainWindow(_FindDart findWindow, _HeapAllocDart heapAlloc, _HeapDart getProcessHeap) {
  const String className = 'FLUTTER_RUNNER_WIN32_WINDOW';
  final Pointer<Uint8> name = heapAlloc(getProcessHeap(), 0x00000008 /*zero init*/, (className.length + 1) * 2);
  if (name == nullptr) return 0;
  _writeUtf16(name, 0, className);
  return findWindow(name, nullptr);
}

/// 造一个 DROPFILES（fWide=1）+ UTF-16 双零结尾路径列表的全局内存块。
int _buildHandle(List<String> paths, _AllocDart alloc, _LockDart lock, _UnlockDart unlock) {
  int units = 1; // 列表末尾那个额外的 0
  for (final String path in paths) {
    units += path.length + 1; // 每个路径自己的结尾 0
  }
  final int size = _headerSize + units * 2;
  final int hMem = alloc(_gmemMoveable | _gmemZeroinit, size);
  if (hMem == 0) return 0;
  final Pointer<Uint8> p = lock(hMem);
  if (p == nullptr) return 0;

  _writeU32(p, 0, _headerSize); // pFiles：路径列表相对结构开头的偏移
  _writeU32(p, 4, 0); // pt.x
  _writeU32(p, 8, 0); // pt.y
  _writeU32(p, 12, 0); // fNC
  _writeU32(p, 16, 1); // fWide：后面是 UTF-16

  int offset = _headerSize;
  for (final String path in paths) {
    offset = _writeUtf16(p, offset, path) + 2; // +2 写路径的结尾 0（内存已清零）
  }
  // 列表整体再补一个 0，凑成双零结尾。
  p[offset] = 0;
  p[offset + 1] = 0;

  unlock(hMem);
  return hMem;
}

void _writeU32(Pointer<Uint8> base, int offset, int value) {
  base[offset] = value & 0xFF;
  base[offset + 1] = (value >> 8) & 0xFF;
  base[offset + 2] = (value >> 16) & 0xFF;
  base[offset + 3] = (value >> 24) & 0xFF;
}

int _writeUtf16(Pointer<Uint8> base, int offset, String text) {
  int o = offset;
  for (final int unit in text.codeUnits) {
    base[o] = unit & 0xFF;
    base[o + 1] = (unit >> 8) & 0xFF;
    o += 2;
  }
  return o;
}
