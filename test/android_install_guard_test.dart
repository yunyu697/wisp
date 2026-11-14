import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android 安装链路的源码级护栏。
///
/// 本机没有 Android SDK / kotlinc，原生代码只能靠 CI `Build android` 编译，
/// 而 2.2.1 的 "packageInfo is null" 偏偏是**运行时**才暴露的问题：把
/// MediaStore 的 content:// 直接交给系统安装器，安装器 StagingAsyncTask
/// 复制出空包，AOSP 的 PackageUtil.getPackageInfo 返回 null。这里把
/// 「安装必须走本应用 FileProvider 授权的本地文件」和「源副本不能删」
/// 两条不变量钉在源码上，防止以后又被"优化"回去。
void main() {
  final File kotlin =
      File('android/app/src/main/kotlin/app/wisp/wisp/MainActivity.kt');
  final File installer = File('lib/services/update_installer.dart');
  final File paths = File('android/app/src/main/res/xml/file_paths.xml');

  /// 只截目标函数/方法本体，避免别处的同名字符串把断言糊过去。
  String section(String source, String start, String end) {
    final int a = source.indexOf(start);
    if (a < 0) return '';
    final int b = source.indexOf(end, a + start.length);
    return b < 0 ? source.substring(a) : source.substring(a, b);
  }

  test('installApk 不再把 MediaStore content:// 直接交给安装器', () {
    final String body = section(
      kotlin.readAsStringSync(),
      'private fun installApk(',
      '/** 把安装句柄统一落成本应用可读',
    );
    expect(body, isNot(contains('Uri.parse(target)')));
    expect(body, contains('resolveInstallableApk(target)'));
    expect(body, contains('FileProvider.getUriForFile'));
    expect(body, contains('ClipData.newUri'));
    expect(body, contains('FLAG_GRANT_READ_URI_PERMISSION'));
  });

  test('发布到系统下载目录后会自检 APK 完整性', () {
    final String body = section(
      kotlin.readAsStringSync(),
      'private fun saveToDownloads(',
      '/** 发布成功后记下源副本',
    );
    expect(body, contains('written != src.length()'));
    expect(body, contains('0x50.toByte()'));
    expect(body, contains('IS_PENDING'));
    expect(body, contains('contentResolver.delete(uri, null, null)'));
  });

  test('安装句柄优先用已校验的源副本，MediaStore 回读只作兜底', () {
    final String body = section(
      kotlin.readAsStringSync(),
      '/** 把安装句柄统一落成本应用可读',
      '/** 用系统默认应用打开聊天附件',
    );
    expect(body, contains('lastPublishedPath'));
    expect(body, contains('stageContentUri(target)'));
    expect(body, contains('isUsableApk('));
  });

  test('FileProvider 能授权应用 cache 里的安装副本', () {
    expect(paths.readAsStringSync(), contains('cache-path'));
  });

  test('Dart 保留源副本兜底，并把 invalid_apk 翻成可照做的文案', () {
    final String source = installer.readAsStringSync();
    final String publish = section(
      source,
      'static Future<String> _publishAndroid(',
      '/// 给用户看的结果文案里怎么称呼这个包',
    );
    expect(publish, isNot(contains('File(path).delete()')));
    final String install = section(
      source,
      'static Future<UpdateInstallOutcome> _installAndroid(',
      '// ---------------------------------------------------------------------',
    );
    expect(install, contains("case 'invalid_apk':"));
    expect(install, contains('重新下载'));
  });
}
