/// 用系统默认程序打开一个本地文件。
///
/// 聊天记录里的附件以前只有图片能点（应用内看大图），其它文件点了完全
/// 没反应。桌面用 ShellExecute / open / xdg-open，Android 走 `wisp/android`
/// 通道的 ACTION_VIEW + FileProvider（分区存储下不能直接把 file:// 交给别的应用）。
library;

import 'dart:io';

import '../../services/android_platform.dart';

class OpenFileResult {
  const OpenFileResult({required this.opened, this.message});

  final bool opened;
  final String? message;

  static const OpenFileResult ok = OpenFileResult(opened: true);

  static OpenFileResult fail(String message) =>
      OpenFileResult(opened: false, message: message);
}

Future<OpenFileResult> openLocalFile(String path) async {
  if (path.trim().isEmpty) {
    return OpenFileResult.fail('这个附件没有可用的本地路径');
  }
  if (!File(path).existsSync()) {
    return OpenFileResult.fail('文件已经不在原来的位置了，可在「文件」页重发');
  }

  if (Platform.isAndroid) {
    final bool ok = await WispAndroid.openFile(path);
    return ok
        ? OpenFileResult.ok
        : OpenFileResult.fail('没有能打开这类文件的应用，或系统拒绝访问该文件');
  }

  try {
    if (Platform.isWindows) {
      // start 的第一对空引号是窗口标题占位，路径里有空格也不会被拆开。
      await Process.run('cmd', <String>['/c', 'start', '', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', <String>[path]);
    } else {
      return OpenFileResult.fail('当前平台暂不支持打开文件');
    }
    return OpenFileResult.ok;
  } catch (_) {
    return OpenFileResult.fail('没能唤起系统程序打开这个文件');
  }
}
