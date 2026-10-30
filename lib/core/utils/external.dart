import 'dart:io';

/// 用系统默认方式打开外链（浏览器）。
///
/// 只在用户明确点击后调用；失败静默返回，调用方用 SnackBar 兜底提示。
Future<void> openExternal(String url) async {
  if (Platform.isWindows) {
    // explorer.exe 能把 http(s) 转交给默认浏览器，且不需要 shell 转义。
    await Process.run('explorer.exe', <String>[url]);
  } else if (Platform.isMacOS) {
    await Process.run('open', <String>[url]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', <String>[url]);
  } else if (Platform.isAndroid) {
    // Android 上没有可靠的免插件方案，交给 Intent 由平台通道处理是后续工作；
    // 桌面端是主场景，这里保留空实现避免误编译失败。
  }
}
