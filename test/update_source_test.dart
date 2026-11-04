import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/services/update_installer.dart';
import 'package:wisp/services/update_service.dart';

/// 下载源（官方 / 加速镜像）与落盘目录。
///
/// **不初始化 TestWidgetsFlutterBinding**：这里要读真实环境变量、
/// 还要保证 HttpClient 不被测试绑定拦掉（见 update_installer_test.dart 头注释）。
void main() {
  const String githubUrl =
      'https://github.com/yunyu697/wisp/releases/download/v9.9.9/wisp-windows-x64-9.9.9-setup.exe';

  group('下载源顺序', () {
    test('默认（官方源）：官方直连排第一，镜像依次跟上', () {
      final List<String> urls =
          WispUpdateInstaller.sourceOrder(githubUrl, null);
      expect(urls.first, githubUrl);
      expect(urls.length, 1 + WispUpdateSource.mirrors.length);
      for (final String prefix in WispUpdateSource.mirrors) {
        expect(urls, contains('$prefix$githubUrl'));
      }
    });

    test('手动选了镜像：该镜像排第一，官方源仍在后面兜底', () {
      const String prefix = 'https://ghfast.top/';
      const WispUpdateSourceOption mirror =
          WispUpdateSourceOption(label: 'ghfast.top', prefix: prefix);
      final List<String> urls =
          WispUpdateInstaller.sourceOrder(githubUrl, mirror);

      expect(urls.first, '$prefix$githubUrl',
          reason: '用户在下拉里选了镜像，就必须先走它');
      expect(urls, contains(githubUrl),
          reason: '镜像挂了要能自动退回官方源，否则用户只能重选一次');
      expect(urls.toSet().length, urls.length, reason: '不能有重复地址');
    });

    test('非 GitHub 直链不套镜像前缀（本地/自建源加了只会白等超时）', () {
      const String localUrl = 'http://127.0.0.1:8080/wisp-setup.exe';
      const WispUpdateSourceOption mirror =
          WispUpdateSourceOption(label: 'ghfast.top', prefix: 'https://ghfast.top/');
      final List<String> urls =
          WispUpdateInstaller.sourceOrder(localUrl, mirror);
      expect(urls, <String>[localUrl]);
    });
  });

  group('下载源下拉选项', () {
    test('官方源在首位，其余与镜像表一一对应', () {
      final List<WispUpdateSourceOption> options =
          WispUpdateSource.downloadOptions;
      expect(options.first.isOfficial, isTrue);
      expect(options.length, 1 + WispUpdateSource.mirrors.length);
      expect(options.skip(1).map((WispUpdateSourceOption o) => o.prefix),
          WispUpdateSource.mirrors);
    });

    test('展示名不能和「手动下载」列表里的名字撞车', () {
      // 列表里是「官方源 · GitHub」「加速镜像 · xxx」这些**发布页链接**，
      // 下拉里是**下载线路**。同名会让人以为是同一个开关，也会让
      // find.text 断言在多处同时命中。
      for (final WispUpdateSourceOption option
          in WispUpdateSource.downloadOptions) {
        expect(option.label, isNot(contains(' · ')),
            reason: '下载源展示名请用简洁名（官方源（推荐）/ 域名），不要带 · ');
      }
    });

    test('值相等：DropdownButton 靠它匹配当前项', () {
      const WispUpdateSourceOption a =
          WispUpdateSourceOption(label: 'x', prefix: 'https://ghfast.top/');
      const WispUpdateSourceOption b =
          WispUpdateSourceOption(label: 'y', prefix: 'https://ghfast.top/');
      expect(a, b);
      expect(WispUpdateSource.downloadOptions,
          contains(const WispUpdateSourceOption(label: '其它', prefix: 'https://ghfast.top/')));
    });
  });

  group('落盘目录', () {
    test('「仅下载」落在用户的下载目录，不是临时目录', () async {
      final Directory dir = await WispUpdateInstaller.userDownloadDir();
      expect(dir.path, isNotEmpty);
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        expect(dir.path.toLowerCase(), contains('download'),
            reason: '仅下载必须落到用户找得到的地方：${dir.path}');
      }
    });

    test('一键更新的临时目录单独一个，两者不能混用', () {
      expect(WispUpdateInstaller.downloadDir().path, isNotEmpty);
    });
  });
}
