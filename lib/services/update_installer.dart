/// 更新的「下载 + 安装」执行层。
///
/// 与 [WispUpdateService]（检查清单）分层：这里负责把安装包真的拉下来、
/// 并在支持的平台上替用户装好。
///
/// 自动安装的平台支持（有意为之，不是偷懒）：
/// · Windows —— 启动 Inno Setup 安装器（/SILENT），UAC 确认后全程无感，
///   装完自动拉起新版（wisp.iss 的 [Run] 去掉了 skipifsilent）；
/// · macOS —— hdiutil 挂载 dmg、拷进 /Applications，完成后提示重启生效；
///   /Applications 无写权限时退回"给你打开 dmg 自己拖"；
/// · Linux —— 发行版包管理器各异（deb/rpm/AppImage/tar），强上 pkexec
///   风险大于收益，只做"仅下载"；
/// · Android —— 装第三方 apk 要申请"未知来源安装"权限链，只做"仅下载"。
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'desktop_service.dart';
import 'update_service.dart';

/// 一次安装尝试的结果。`ok` 只表示"我们这边能做的都做成了"——
/// Windows 的 UAC 确认、macOS 的重启生效仍需要用户接一下。
class UpdateInstallOutcome {
  const UpdateInstallOutcome({
    required this.ok,
    required this.message,
    this.installerPath,
  });

  final bool ok;
  final String message;
  final String? installerPath;
}

class WispUpdateInstaller {
  const WispUpdateInstaller._();

  /// 当前平台能否在下载后自动完成安装。
  static bool get supportsAutoInstall {
    if (Platform.isWindows) return true;
    if (Platform.isMacOS) return true;
    return false;
  }

  /// 下载当前平台安装包，返回本地文件路径。
  ///
  /// 官方源失败自动换镜像逐个重试（与清单检查同一套源顺序）。
  /// [info] 供测试注入已拿到的清单；null 时现场查一次。
  /// [onProgress] 参数为（已收字节, 总字节），总长未知时为 0。
  /// [requireVerified] 为 true 时（一键更新），清单必须给出本平台的 sha256，
  /// 且下载结果必须逐字节对得上；否则拒绝安装。为 false 时（仅下载）允许
  /// 没有校验值，但仍然会在有校验值时比对。
  static Future<String> download({
    void Function(int received, int total)? onProgress,
    WispUpdateInfo? info,
    bool requireVerified = true,
  }) async {
    final WispUpdateInfo? manifest = info ?? await WispUpdateService.check();
    final String primary = manifest?.primaryUrl ?? WispUpdateSource.releasePageUrl;
    if (primary == WispUpdateSource.releasePageUrl) {
      // 清单里没有本平台直链：别瞎猜，让用户去发布页挑。
      throw StateError('清单里没有本平台（$platformKey）的下载直链');
    }
    final String? expected = manifest?.expectedSha256;
    if (requireVerified && expected == null) {
      // 清单被换掉、或只拿到仓库里那份手写清单（没有 sha256）时会走到这里。
      // 没有摘要就不自动装——否则等于"从第三方镜像下个 exe 就提权运行"。
      throw StateError('更新清单没有提供校验值，已取消自动安装；请改用「仅下载」后手动安装');
    }
    // 镜像只代理 GitHub 地址；本地/自建源拼上前缀毫无意义，还会白等超时。
    final bool mirrorable = primary.contains('github.com/');
    final List<String> urls = <String>[
      primary,
      if (mirrorable)
        for (final String prefix in WispUpdateSource.mirrors) '$prefix$primary',
    ];
    Object? lastError;
    bool tampered = false;
    for (final String url in urls) {
      try {
        final String path = await _downloadOne(url, onProgress);
        if (expected == null) return path;
        final String actual = await sha256OfFile(path);
        if (actual == expected) return path;
        // 校验不过就删掉再换源：坏包不能留在磁盘上被用户手动点开。
        try {
          await File(path).delete();
        } catch (_) {
          // 删不掉（被杀软占用之类）也要继续换源。
        }
        tampered = true;
        lastError = StateError('安装包校验失败（来源 $url），已丢弃');
      } catch (e) {
        lastError = e; // 换下一个源。
      }
    }
    // 校验失败是安全事件，不能被后续镜像的网络错误盖掉——用户要知道
    // "下到的包是错的"，而不是"网不好"。
    if (tampered) throw lastError!;
    throw StateError('所有下载源都失败了：$lastError');
  }

  /// 文件的 sha256（小写十六进制），流式计算，不把整个安装包读进内存。
  static Future<String> sha256OfFile(String path) async {
    final Digest digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  static Future<String> _downloadOne(
    String url,
    void Function(int received, int total)? onProgress,
  ) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      final HttpClientResponse response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final String fileName = _fileNameFromUrl(url);
      if (fileName.isEmpty) throw StateError('拿不到下载文件名：$url');
      final Directory dir = downloadDir();
      await dir.create(recursive: true);
      // 下载到临时名再改名：中断残留的半个文件不能冒充安装包。
      final File target = File('${dir.path}${Platform.pathSeparator}$fileName');
      final File partial =
          File('${target.path}.part');
      final IOSink sink = partial.openWrite();
      int received = 0;
      final int total = response.contentLength;
      try {
        await for (final List<int> chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (total > 0 && received < total) {
        throw StateError('下载不完整：$received / $total');
      }
      await partial.rename(target.path);
      return target.path;
    } finally {
      client.close(force: true);
    }
  }

  /// 从下载地址取文件名（忽略 query 与镜像前缀）。
  static String _fileNameFromUrl(String url) {
    final Uri uri = Uri.tryParse(url) ?? Uri();
    final List<String> segments =
        uri.pathSegments.where((String s) => s.trim().isNotEmpty).toList();
    return segments.isEmpty ? '' : segments.last;
  }

  /// 安装包保存目录：
  /// · Windows / macOS 放系统临时目录——装完即弃，别占用户空间；
  /// · Linux / Android 走"仅下载"，要放用户找得到的地方。
  static Directory downloadDir() {
    if (Platform.isLinux) {
      final String? home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        return Directory('$home/Downloads');
      }
    }
    if (Platform.isAndroid) {
      // Android 专属外部文件目录无需存储权限；路径长，但界面上会完整展示。
      // getExternalStorageDirectory 在 plugin 侧，这里用环境约定路径兜底。
      return Directory.systemTemp;
    }
    return Directory.systemTemp;
  }

  /// 自动安装。只该在 [supportsAutoInstall] 为 true 的平台调用。
  static Future<UpdateInstallOutcome> install(String filePath) async {
    if (Platform.isWindows) return _installWindows(filePath);
    if (Platform.isMacOS) return _installMacos(filePath);
    return const UpdateInstallOutcome(
      ok: false,
      message: '当前平台不支持自动安装，请手动安装下载好的安装包',
    );
  }

  // ---------------------------------------------------------------------
  // Windows：启动 Inno Setup 安装器（静默 + 装完自动拉起新版）。
  // ---------------------------------------------------------------------

  static Future<UpdateInstallOutcome> _installWindows(String filePath) async {
    // .iss 里 PrivilegesRequired=admin，安装要提权——必须走原生
    // ShellExecuteW（runas），CreateProcess 启动带 admin 清单的 exe 会直接报
    // ERROR_ELEVATION_REQUIRED。
    final bool launched = await DesktopService.runInstaller(
      filePath,
      args: const <String>['/SILENT', '/SUPPRESSMSGBOXES'],
    );
    if (!launched) {
      return UpdateInstallOutcome(
        ok: false,
        message: '没能启动安装程序（UAC 确认被取消或被安全软件拦截），可手动运行：$filePath',
        installerPath: filePath,
      );
    }
    return const UpdateInstallOutcome(
      ok: true,
      message: '安装程序已启动：确认 UAC 后会静默完成安装并自动打开新版 Wisp',
    );
  }

  // ---------------------------------------------------------------------
  // macOS：挂载 dmg -> 拷贝到 /Applications -> 卸载镜像。
  // ---------------------------------------------------------------------

  static Future<UpdateInstallOutcome> _installMacos(String dmgPath) async {
    ProcessResult attach;
    try {
      attach = await Process.run('hdiutil', <String>[
        'attach',
        '-nobrowse',
        '-readonly',
        dmgPath,
      ]);
    } catch (e) {
      return UpdateInstallOutcome(
          ok: false, message: '挂载安装镜像失败：$e', installerPath: dmgPath);
    }
    if (attach.exitCode != 0) {
      return UpdateInstallOutcome(
        ok: false,
        message: '挂载安装镜像失败：${attach.stderr}'.trim(),
        installerPath: dmgPath,
      );
    }

    // hdiutil 的 stdout 里带挂载点（/Volumes/...）。
    final RegExp volumePattern = RegExp(r'/Volumes/[^\t\n]+');
    final RegExpMatch? match = volumePattern.firstMatch(attach.stdout.toString());
    if (match == null) {
      return UpdateInstallOutcome(
          ok: false, message: '没有在镜像输出里找到挂载卷', installerPath: dmgPath);
    }
    final String volume = match.group(0)!.trim();

    // 卷里找 .app（按 Flutter 构建产物约定叫 wisp.app，扫描兜底改名）。
    Directory? appBundle;
    for (final FileSystemEntity entity in Directory(volume).listSync()) {
      if (entity is Directory && entity.path.endsWith('.app')) {
        appBundle = entity;
        break;
      }
    }
    if (appBundle == null) {
      await Process.run('hdiutil', <String>['detach', volume, '-force']);
      return UpdateInstallOutcome(
        ok: false,
        message: '镜像里没有找到应用，请手动把 $volume 里的应用拖进「应用程序」',
        installerPath: dmgPath,
      );
    }

    final ProcessResult copy =
        await Process.run('cp', <String>['-R', '-f', appBundle.path, '/Applications/']);
    // 无论拷没拷成，镜像都要卸掉，不留空卷。
    await Process.run('hdiutil', <String>['detach', volume, '-force']);

    if (copy.exitCode != 0) {
      return UpdateInstallOutcome(
        ok: false,
        message: '写入「应用程序」失败（${copy.stderr}）。'
            '常见原因是当前账号没有权限：请手动把 dmg 里的应用拖进「应用程序」',
        installerPath: dmgPath,
      );
    }
    return const UpdateInstallOutcome(
      ok: true,
      message: '已更新到「应用程序」。退出并重新打开 Wisp 即可生效',
    );
  }
}
