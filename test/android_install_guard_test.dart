import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android 安装链路的源码级护栏。
///
/// 本机没有 Android SDK / kotlinc，原生代码只能靠 CI `Build android` 编译，
/// 而 "packageInfo is null" 偏偏是**运行时**才暴露的问题：AOSP 的
/// PackageInstallerActivity 内部调 PackageUtil.getPackageInfo，拿到 null
/// 就弹一句用户完全无法照做的错误。踩过两次：
/// · 2.2.1 —— 把 MediaStore 的 content:// 直接交给安装器，它读不到字节；
/// · 2.2.2 —— 换成 FileProvider 授权了，但安装句柄仍是 content://，且部分
///   ROM 的安装器会把 URI 转交另一个进程，跨进程读不到授权，照样是空包。
/// 2.2.3 起改成 PackageInstaller 会话：字节由我们直接写进系统安装会话，
/// 不存在"安装器读不到"这种失败。下面这些不变量没法在 Dart 层测出来，
/// 只能钉在源码上，防止以后又被"优化"回去。
void main() {
  final File kotlin =
      File('android/app/src/main/kotlin/app/wisp/wisp/MainActivity.kt');
  final File receiver =
      File('android/app/src/main/kotlin/app/wisp/wisp/InstallResultReceiver.kt');
  final File manifest = File('android/app/src/main/AndroidManifest.xml');
  final File installer = File('lib/services/update_installer.dart');
  final File paths = File('android/app/src/main/res/xml/file_paths.xml');

  /// 只截目标函数/方法本体，避免别处的同名字符串把断言糊过去。
  String section(String source, String start, String end) {
    final int a = source.indexOf(start);
    if (a < 0) return '';
    final int b = source.indexOf(end, a + start.length);
    return b < 0 ? source.substring(a) : source.substring(a, b);
  }

  test('安装跑在后台线程，不占平台线程写几十 MB', () {
    final String body = section(
      kotlin.readAsStringSync(),
      'private fun installApkAsync(',
      'private fun installApk(',
    );
    expect(body, contains('Thread {'));
    expect(body, contains('runOnUiThread'));
    expect(body, contains('canRequestPackageInstalls'));
    expect(body, contains('openUnknownSourcesSettings()'));
  });

  test('安装优先走 PackageInstaller 会话，URI 只作兜底', () {
    final String body = section(
      kotlin.readAsStringSync(),
      'private fun installApk(',
      'private fun installViaSession(',
    );
    expect(body, contains('installViaSession(apk)'));
    expect(body, contains('installViaUri(apk)'));
  });

  test('会话把字节直接写进系统，不走 ContentProvider', () {
    final String body = section(
      kotlin.readAsStringSync(),
      'private fun installViaSession(',
      'private fun installResultSender(',
    );
    expect(body, contains('MODE_FULL_INSTALL'));
    expect(body, contains('openWrite(SESSION_APK'));
    // 写完必须 fsync：否则 commit 时系统可能读到还没落盘的尾巴。
    expect(body, contains('session.fsync(out)'));
    expect(body, contains('session.commit('));
    // 建不起会话要清干净，不留半截 session 占配额。
    expect(body, contains('abandonSession'));
  });

  test('会话结果回调的 PendingIntent 在 Android 12+ 声明可变', () {
    final String body = section(
      kotlin.readAsStringSync(),
      'private fun installResultSender(',
      'private fun installViaUri(',
    );
    expect(body, contains('PendingIntent.FLAG_MUTABLE'));
    expect(body, contains('PendingIntent.FLAG_UPDATE_CURRENT'));
    expect(body, contains('InstallResultReceiver'));
  });

  test('URI 兜底路径只交本地文件，且不再声明"可信来源"', () {
    final String body = section(
      kotlin.readAsStringSync(),
      'private fun installViaUri(',
      'private fun openUnknownSourcesSettings(',
    );
    expect(body, contains('FileProvider.getUriForFile'));
    expect(body, contains('uriReadsWholeFile'));
    expect(body, contains('startInstaller(uri)'));
    expect(body, contains('invalid_apk'));
    // EXTRA_NOT_UNKNOWN_SOURCE 是"调用方可信"的声明，普通应用设它会让部分
    // ROM 走需要 INSTALL_PACKAGES 权限的分支然后失败。
    expect(kotlin.readAsStringSync(), isNot(contains('EXTRA_NOT_UNKNOWN_SOURCE')));
  });

  test('安装前用系统自己的解析器验包，坏包不交给安装器', () {
    final String source = kotlin.readAsStringSync();
    final String body = section(
      source,
      'private fun parsesAsWispApk(',
      'private fun stageForInstall(',
    );
    expect(body, contains('getPackageArchiveInfo'));
    expect(body, contains('packageName'));
    expect(body, contains('0x50.toByte()'));
  });

  test('安装句柄先复制进 cache 并 fsync，再核对长度', () {
    final String body = section(
      kotlin.readAsStringSync(),
      'private fun stageForInstall(',
      'private fun installStagingDir(',
    );
    expect(body, contains('fd.sync()'));
    expect(body, contains('dest.length() == src.length()'));
  });

  test('候选句柄按"能解析出本应用的包"逐个筛选', () {
    final String body = section(
      kotlin.readAsStringSync(),
      'private fun resolveInstallableApk(',
      'private fun parsesAsWispApk(',
    );
    expect(body, contains('parsesAsWispApk('));
    expect(body, contains('stageForInstall('));
    expect(body, contains('lastPublishedPath'));
    expect(body, contains('installStagingDir()'));
  });

  test('授权出去的 URI 必须能读出与文件等长的字节', () {
    final String body = section(
      kotlin.readAsStringSync(),
      'private fun uriReadsWholeFile(',
      'private fun resolveInstallableApk(',
    );
    expect(body, contains('openFileDescriptor'));
    expect(body, contains('statSize == expected'));
  });

  test('发布到系统下载目录后按长度自检，不只看 4 字节魔数', () {
    final String body = section(
      kotlin.readAsStringSync(),
      'private fun saveToDownloads(',
      'private fun rememberPublished(',
    );
    expect(body, contains('written != src.length()'));
    // 截断包的头部照样是 PK\x03\x04，必须比对实际 size。
    expect(body, contains('size != src.length()'));
    expect(body, contains('IS_PENDING'));
    expect(body, contains('contentResolver.delete(uri, null, null)'));
  });

  test('会话结果接收器存在并在清单里静态注册', () {
    expect(receiver.existsSync(), isTrue);
    expect(receiver.readAsStringSync(), contains('EXTRA_STATUS_MESSAGE'));
    final String xml = manifest.readAsStringSync();
    expect(xml, contains('android:name=".InstallResultReceiver"'));
    expect(xml, contains('android:exported="false"'));
  });

  test('Dart 侧安装句柄与展示位置分离，安装只传本地路径', () {
    final String source = installer.readAsStringSync();
    final String publish = section(
      source,
      'static Future<String> _publishAndroid(',
      'static String describeArtifact(',
    );
    expect(publish, contains('return path;'));
    expect(publish, isNot(contains('return published;')));
    final String install = section(
      source,
      'static Future<UpdateInstallOutcome> _installAndroid(',
      '// ---------------------------------------------------------------------',
    );
    expect(install, contains("case 'invalid_apk':"));
    expect(install, contains('重新'));
  });

  test('FileProvider 能授权应用 cache 里的安装副本', () {
    expect(paths.readAsStringSync(), contains('cache-path'));
  });
}
