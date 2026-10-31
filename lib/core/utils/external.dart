import 'dart:io';

import 'package:flutter/services.dart';

/// 打开外链的结果。
///
/// 调用方据此决定要不要提示用户——「点了没反应」是最糟的体验，
/// 至少要让用户知道浏览器没被拉起来。
class ExternalOpenResult {
  const ExternalOpenResult({required this.opened, this.message});

  /// 是否成功把链接交给了系统。
  final bool opened;

  /// 失败原因（给用户看的中文提示）；成功时为 null。
  final String? message;

  static const ExternalOpenResult ok = ExternalOpenResult(opened: true);
}

/// 只放行 http/https 链接。
///
/// URL 是外部输入（update.json、远端返回），交给 ShellExecute 前必须先筛：
/// 那 API 能执行 exe、能打开本地文件，放行 file:// 或 javascript: 等于开了
/// 个任意执行的口子。原生层也做同样的校验，两边都拦才算稳。
bool isOpenableWebUrl(String url) {
  final String trimmed = url.trim();
  if (trimmed.isEmpty) return false;
  final String lower = trimmed.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

/// 用系统默认方式打开外链（浏览器）。
///
/// Windows 走原生通道 `openUrl`：原生层用 `ShellExecuteW` 把 http(s) 交给
/// 默认浏览器。这里**不能**用 `explorer.exe <url>` —— 从 Flutter 起的子进程
/// 没有正确的交互式桌面关联，explorer.exe 收下 URL 却不打开浏览器，
/// 表现就是「点了下载链接没反应」。
///
/// macOS / Linux 用系统的 open / xdg-open；Android 没有可靠的免插件方案，
/// 保留空实现（桌面端是主场景）。
Future<ExternalOpenResult> openExternal(String url) async {
  if (url.trim().isEmpty) {
    return const ExternalOpenResult(
        opened: false, message: '链接为空，无法打开');
  }
  if (!isOpenableWebUrl(url)) {
    return const ExternalOpenResult(
        opened: false, message: '只支持打开 http/https 链接');
  }

  if (Platform.isWindows) {
    // 原生通道拿不到（老版本应用 / 通道异常）时退回 explorer.exe，
    // 至少比什么都不做强。
    try {
      final bool? ok = await const MethodChannel('wisp/desktop')
          .invokeMethod<bool>('openUrl', <String, String>{'url': url});
      if (ok == true) return ExternalOpenResult.ok;
      if (ok == false) {
        return const ExternalOpenResult(
            opened: false, message: '没能唤起浏览器，请手动复制链接下载');
      }
    } on MissingPluginException {
      // 通道不存在，往下走。
    } on PlatformException {
      // 原生层异常，往下走。
    }
    try {
      await Process.run('explorer.exe', <String>[url]);
      return ExternalOpenResult.ok;
    } catch (_) {
      return const ExternalOpenResult(
          opened: false, message: '没能唤起浏览器，请手动复制链接下载');
    }
  }

  if (Platform.isMacOS) {
    try {
      await Process.run('open', <String>[url]);
      return ExternalOpenResult.ok;
    } catch (_) {
      return const ExternalOpenResult(
          opened: false, message: '没能唤起浏览器，请手动复制链接下载');
    }
  }

  if (Platform.isLinux) {
    try {
      await Process.run('xdg-open', <String>[url]);
      return ExternalOpenResult.ok;
    } catch (_) {
      return const ExternalOpenResult(
          opened: false, message: '没能唤起浏览器，请手动复制链接下载');
    }
  }

  // Android：没有可靠的免插件方案，交给 Intent 由平台通道处理是后续工作。
  return const ExternalOpenResult(
      opened: false, message: '当前平台暂不支持直接打开链接，请手动复制到浏览器');
}
