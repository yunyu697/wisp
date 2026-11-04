/// 更新的「下载 + 安装」执行层。
///
/// 与 [WispUpdateService]（检查清单）分层：这里负责把安装包真的拉下来、
/// 并在支持的平台上替用户装好。
///
/// 自动安装的平台支持（有意为之，不是偷懒）：
/// · Windows —— 启动 Inno Setup 安装器（/SILENT），UAC 确认后全程无感，
///   装完自动拉起新版（wisp.iss 的静默安装启动项走 WizardSilent 判断，
///   不能用 postinstall —— /SILENT 不显示完成页，那条永远不会执行）；
/// · macOS —— hdiutil 挂载 dmg、替换 /Applications 里的应用，然后自动重启；
///   /Applications 无写权限时退回"给你打开 dmg 自己拖"；
/// · Linux —— 发行版包管理器各异（deb/rpm/AppImage/tar），强上 pkexec
///   风险大于收益，只做"仅下载"；
/// · Android —— 装第三方 apk 要申请"未知来源安装"权限链，只做"仅下载"。
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'desktop_service.dart';
import 'update_service.dart';

/// 一次安装尝试的结果。`ok` 只表示"我们这边能做的都做成了"——
/// Windows 的 UAC 确认仍需要用户接一下（之后全自动）。
class UpdateInstallOutcome {
  const UpdateInstallOutcome({
    required this.ok,
    required this.message,
    this.installerPath,
    this.restartPath,
  });

  final bool ok;
  final String message;
  final String? installerPath;

  /// 非空表示：装完了，应该重启到这个 .app（macOS）。
  /// Windows 的拉起由安装器自己负责，所以这里一直是 null。
  final String? restartPath;
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
  /// [source] 用户在界面上下拉选的下载源。为空或选官方源时按 官方 → 镜像
  /// 顺序重试；选了某个镜像时**先走它**，失败再按默认顺序兜底——镜像站
  /// 挂掉是常事，让用户重选一遍不如自动退回去。
  /// [info] 供测试注入已拿到的清单；null 时现场查一次。
  /// [onProgress] 参数为（已收字节, 总字节），总长未知时为 0。
  /// [requireVerified] 为 true 时（一键更新），清单必须给出本平台的 sha256，
  /// 且下载结果必须逐字节对得上；否则拒绝安装。为 false 时（仅下载）允许
  /// 没有校验值，但仍然会在有校验值时比对。
  /// [targetDir] 落盘目录。一键更新给临时目录（装完即弃）；「仅下载」给
  /// 用户的下载目录（[userDownloadDir]），下完要能被找到、能手动安装。
  static Future<String> download({
    void Function(int received, int total)? onProgress,
    WispUpdateInfo? info,
    bool requireVerified = true,
    WispUpdateSourceOption? source,
    Directory? targetDir,
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
    final List<String> urls = sourceOrder(primary, source);
    final Directory dir = targetDir ?? downloadDir();
    Object? lastError;
    bool tampered = false;
    for (final String url in urls) {
      try {
        final String path = await _downloadOne(url, onProgress, dir);
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

  /// 下载尝试顺序：用户选的源排第一，其余按 官方 → 镜像 兜底。
  ///
  /// 公开给测试：这条顺序决定了"用户在下拉里选了镜像，就真的先走镜像"，
  /// 光看下载结果看不出来（本地回环测试里官方源也在线）。
  static List<String> sourceOrder(String primary, WispUpdateSourceOption? source) {
    // 镜像只代理 GitHub 地址；本地/自建源拼上前缀毫无意义，还会白等超时。
    final bool mirrorable = primary.contains('github.com/');
    final List<String> fallback = <String>[
      primary,
      if (mirrorable)
        for (final String prefix in WispUpdateSource.mirrors) '$prefix$primary',
    ];
    final String? prefix = source?.prefix;
    if (prefix == null || !mirrorable) return fallback;
    final String chosen = '$prefix$primary';
    return <String>[chosen, ...fallback.where((String u) => u != chosen)];
  }

  /// 文件的 sha256（小写十六进制），流式计算，不把整个安装包读进内存。
  static Future<String> sha256OfFile(String path) async {
    final Digest digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  static Future<String> _downloadOne(
    String url,
    void Function(int received, int total)? onProgress,
    Directory dir,
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

  /// 「一键更新」用的临时落盘目录：装完即弃，不该占用户空间。
  static Directory downloadDir() => Directory.systemTemp;

  /// 「仅下载」用的落盘目录：**用户的默认下载目录**。
  ///
  /// 以前无论哪种下载都丢进系统临时目录——用户点「仅下载」之后既看不到
  /// 文件、也没法安装，等于白下。现在下到用户自己会去的地方：
  /// Windows `%USERPROFILE%\Downloads`、macOS/Linux `~/Downloads`、
  /// Android 应用外部目录（无需存储权限）。
  ///
  /// path_provider 拿不到时（测试环境、精简系统）退回按环境变量拼，
  /// 再不行才用临时目录——绝不让下载因为"找不到下载夹"而失败。
  static Future<Directory> userDownloadDir() async {
    try {
      final Directory? dir = await getDownloadsDirectory();
      if (dir != null && dir.path.isNotEmpty) return dir;
    } catch (_) {
      // 测试环境没有平台通道，按环境变量兜底。
    }
    if (Platform.isAndroid) {
      try {
        final Directory? external = await getExternalStorageDirectory();
        if (external != null) return external;
      } catch (_) {
        // 继续兜底。
      }
      return Directory.systemTemp;
    }
    final String? home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory('$home${Platform.pathSeparator}Downloads');
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
  // macOS：挂载 dmg -> 替换 /Applications 里的应用 -> 卸载镜像 -> 重启。
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

    final String bundleName = appBundle.uri.pathSegments
        .lastWhere((String s) => s.isNotEmpty, orElse: () => 'wisp.app');
    final String target = '/Applications/$bundleName';
    // 先整包拷到旁边的暂存名，再整体替换。
    //
    // 不能直接 `cp -R -f src.app /Applications/`：目标已存在时 BSD cp 会把新包
    // 塞进旧包内部（/Applications/Wisp.app/Wisp.app），替换后主程序仍是旧版本，
    // 用户会以为"更新没生效"。用 ditto 而不是 cp，是为了保符号链接与权限位
    // （Flutter 的 .app 里有 Frameworks 软链，cp -R 会跟进去拷成实体目录）。
    final String staging = '/Applications/.$bundleName.incoming';
    final ProcessResult copy =
        await Process.run('ditto', <String>['--noqtn', appBundle.path, staging]);
    // 无论成没成，镜像都要卸掉，不留空卷。
    await Process.run('hdiutil', <String>['detach', volume, '-force']);

    Future<UpdateInstallOutcome> bail(String detail) async {
      await Process.run('rm', <String>['-rf', staging]);
      // 自动装不了至少别让用户自己去满硬盘找安装包。
      await _openPath(dmgPath);
      return UpdateInstallOutcome(
        ok: false,
        message: '$detail。已经帮你打开镜像：把里面的应用拖进「应用程序」即可',
        installerPath: dmgPath,
      );
    }

    // 退出码和目录存在性都要看：ditto 失败时也可能留下半个目录。
    if (copy.exitCode != 0 || !Directory(staging).existsSync()) {
      final String detail = copy.stderr.toString().trim();
      return bail('写入「应用程序」失败'
          '${detail.isEmpty ? '（无权限或磁盘空间不足）' : '（$detail）'}');
    }
    final ProcessResult remove =
        await Process.run('rm', <String>['-rf', target]);
    if (remove.exitCode != 0) {
      return bail('替换旧版失败（${remove.stderr}）');
    }
    final ProcessResult move =
        await Process.run('mv', <String>[staging, target]);
    if (move.exitCode != 0) {
      return bail('安装到「应用程序」失败（${move.stderr}）');
    }
    return UpdateInstallOutcome(
      ok: true,
      message: '已更新到「应用程序」，正在重启 Wisp…',
      installerPath: dmgPath,
      restartPath: target,
    );
  }

  /// 把刚装好的应用重新拉起来，然后退出当前进程。
  ///
  /// 不能直接 open：本进程还占着 53317 —— 新旧实例会撞端口，新版直接报
  /// "无法占用端口"。所以交给一个脱离的子 shell：先等本进程真正退出，
  /// 再 open。启动的是 /Applications 里刚替换好的那一份，不是旧的可执行文件。
  static Future<void> restartInto(String appPath) async {
    if (Platform.isMacOS) {
      await Process.start(
        '/bin/sh',
        <String>[
          '-c',
          // 原始字符串：`$1` 是 shell 的位置参数，不能被 Dart 当插值吃掉。
          r'sleep 1.2; exec /usr/bin/open -n "$1"',
          'wisp-relaunch', // $0
          appPath, // $1（走位置参数，路径里有空格或引号都不用转义）
        ],
        mode: ProcessStartMode.detached,
      );
    }
    exit(0);
  }

  /// 用系统默认方式打开一个本地文件（挂载失败的 dmg 兜底用）。
  static Future<void> _openPath(String path) async {
    try {
      await Process.run('open', <String>[path]);
    } catch (_) {
      // 打不开就算了，消息里已经带了路径。
    }
  }
}
