import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:wisp/services/update_service.dart';

/// 更新服务单元测试。**不初始化 TestWidgetsFlutterBinding**——
/// 那个绑定会把所有 HttpClient 请求拦成 400，清单获取测试就全废了。
/// 真实回环 HttpServer 只有在无绑定的纯 Dart 环境里才能通。
/// 弹层 widget 测试在 update_sheet_test.dart。
void main() {
  group('版本比较', () {
    test('三段逐位比较', () {
      expect(WispUpdateService.compareVersions('1.0.13', '1.0.12'), greaterThan(0));
      expect(WispUpdateService.compareVersions('1.0.12', '1.0.13'), lessThan(0));
      expect(WispUpdateService.compareVersions('1.0.12', '1.0.12'), 0);
      expect(WispUpdateService.compareVersions('2.0.0', '1.99.99'), greaterThan(0));
      expect(WispUpdateService.compareVersions('1.1.0', '1.0.99'), greaterThan(0));
    });

    test('段数不齐按 0 补，脏字符按 0 处理', () {
      expect(WispUpdateService.compareVersions('1.1', '1.0.9'), greaterThan(0));
      expect(WispUpdateService.compareVersions('1.0', '1.0.1'), lessThan(0));
      // "1.0.13-beta" 的尾段不是纯数字 → 按 0，视为 1.0.13。
      expect(WispUpdateService.compareVersions('1.0.13-beta', '1.0.13'), 0);
    });

    test('isNewer：相同与更旧都不提示', () {
      expect(WispUpdateService.isNewer('1.0.12', '1.0.12'), isFalse);
      expect(WispUpdateService.isNewer('1.0.11', '1.0.12'), isFalse);
      expect(WispUpdateService.isNewer('1.0.13', '1.0.12'), isTrue);
    });
  });

  group('镜像列表', () {
    test('有若干镜像且都是前缀代理形式', () {
      expect(WispUpdateSource.mirrors.length, greaterThanOrEqualTo(3),
          reason: '镜像少于 3 个就失去「加速」意义了');
      for (final String prefix in WispUpdateSource.mirrors) {
        expect(prefix.startsWith('https://'), isTrue, reason: '$prefix 应是 https');
        expect(prefix.endsWith('/'), isTrue, reason: '$prefix 必须带尾斜杠（前缀拼接约定）');
      }
      expect(
        WispUpdateSource.mirrors.toSet().length,
        WispUpdateSource.mirrors.length,
        reason: '镜像不应重复',
      );
    });

    test('镜像展示名去掉协议与斜杠', () {
      expect(WispUpdateSource.mirrorLabel('https://ghfast.top/'), 'ghfast.top');
    });

    test('下载入口 = 官方 + 镜像，且地址互不相同', () {
      const WispUpdateInfo info = WispUpdateInfo(
        latestVersion: '1.0.13',
        downloadUrl: 'https://github.com/yunyu697/wisp/releases/download/v1.0.13/x.zip',
      );
      final List<(String, String)> entries = info.downloadEntries;
      expect(entries.length, 1 + WispUpdateSource.mirrors.length);
      expect(entries.first.$1, startsWith('官方'));
      final Set<String> urls = entries.map(((String, String) e) => e.$2).toSet();
      expect(urls.length, entries.length, reason: '镜像地址不应重复');
      // 前缀代理：镜像地址 = 镜像前缀 + 官方完整地址。
      expect(entries[1].$2, '${WispUpdateSource.mirrors.first}${info.primaryUrl}');
    });
  });

  group('自动检查频率', () {
    test('关闭时永远不到点，其余从没查过就算到点', () {
      const int now = 1000000;
      expect(WispUpdateCadence.isDue(WispUpdateCadence.off, 0, now), isFalse);
      // 从没查过（lastMs = 0）：每天/每周都立即查一次。
      expect(WispUpdateCadence.isDue(WispUpdateCadence.daily, 0, now), isTrue);
      expect(WispUpdateCadence.isDue(WispUpdateCadence.weekly, 0, now), isTrue);
    });

    test('每次启动无视上次时间，间隔内不到点', () {
      const int now = 100 * 3600000;
      expect(WispUpdateCadence.isDue(WispUpdateCadence.everyStartup, now, now), isTrue);
      expect(WispUpdateCadence.isDue(WispUpdateCadence.everyStartup, now, now + 1), isTrue);
      // 每天：差一小时不到 24h。
      expect(WispUpdateCadence.isDue(WispUpdateCadence.daily, now, now + 23 * 3600000), isFalse);
      expect(WispUpdateCadence.isDue(WispUpdateCadence.daily, now, now + 24 * 3600000), isTrue);
      // 每周：24h 仍不到点，168h 到点。
      expect(WispUpdateCadence.isDue(WispUpdateCadence.weekly, now, now + 24 * 3600000), isFalse);
      expect(
        WispUpdateCadence.isDue(WispUpdateCadence.weekly, now, now + 168 * 3600000),
        isTrue,
      );
    });

    test('标签与选项一一对应，未知值回落到每天', () {
      expect(WispUpdateCadence.label(WispUpdateCadence.off), '关闭');
      expect(WispUpdateCadence.label(WispUpdateCadence.everyStartup), '每次启动');
      expect(WispUpdateCadence.label(WispUpdateCadence.daily), '每天一次');
      expect(WispUpdateCadence.label(WispUpdateCadence.weekly), '每周一次');
      expect(WispUpdateCadence.label(999), '每天一次');
      // 选项值不应重复，否则 RadioListTile 会选中冲突。
      expect(WispUpdateCadence.options.values.toSet().length, WispUpdateCadence.options.length);
    });
  });

  group('清单获取', () {
    late HttpServer server;
    late String manifestUrl;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      manifestUrl = 'http://127.0.0.1:${server.port}/update.json';
      server.listen((HttpRequest request) async {
        if (request.uri.path.endsWith('new.json')) {
          request.response.write(jsonEncode(<String, dynamic>{
            'version': '1.0.13',
            'notes': ' 修了几个 bug，加了新功能 ',
            'downloadUrl': 'https://example.com/wisp.zip',
          }));
        } else if (request.uri.path.endsWith('same.json')) {
          request.response.write(jsonEncode(<String, dynamic>{'version': '1.0.12'}));
        } else if (request.uri.path.endsWith('garbage.json')) {
          request.response.write('not-json');
        } else {
          request.response.statusCode = 500;
        }
        await request.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    test('清单解析：版本 / 说明 / 直链', () async {
      final WispUpdateInfo? info = await WispUpdateService.check(
        sources: <String>[manifestUrl.replaceAll('update.json', 'new.json')],
      );
      expect(info, isNotNull);
      expect(info!.latestVersion, '1.0.13');
      expect(info.notes, '修了几个 bug，加了新功能', reason: '说明文字应去首尾空白');
      expect(info.downloadUrl, 'https://example.com/wisp.zip');
    });

    test('官方失败自动换下一个源（模拟镜像兜底）', () async {
      final String good = manifestUrl.replaceAll('update.json', 'same.json');
      final String bad = manifestUrl.replaceAll('update.json', 'broken.json');
      final WispUpdateInfo? info = await WispUpdateService.check(
        sources: <String>[bad, good],
      );
      expect(info, isNotNull, reason: '第一个源 500 也要继续试第二个');
      expect(info!.latestVersion, '1.0.12');
    });

    test('非法 JSON 与全失败都安全返回 null', () async {
      final String garbage = manifestUrl.replaceAll('update.json', 'garbage.json');
      final WispUpdateInfo? info =
          await WispUpdateService.check(sources: <String>[garbage]);
      expect(info, isNull);
      final WispUpdateInfo? none = await WispUpdateService.check(
        sources: <String>['http://127.0.0.1:1/x.json'],
      );
      expect(none, isNull);
    });

    test('downloadUrl 缺省退回发布页', () async {
      const WispUpdateInfo info = WispUpdateInfo(latestVersion: '1.0.13');
      expect(info.primaryUrl, WispUpdateSource.releasePageUrl);
    });
  });

}
