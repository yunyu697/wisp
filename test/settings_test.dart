
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisp/models/device.dart';
import 'package:wisp/models/network.dart';
import 'package:wisp/services/settings_service.dart';
import 'package:wisp/services/update_service.dart';
import 'package:wisp/state/app_state.dart';

/// 新增的识别用户名、端口、网卡等设置的行为测试。
void main() {
  group('设置序列化', () {
    test('新字段能存能读', () {
      const WispSettings original = WispSettings(
        alias: '测试机',
        fingerprint: 'abc123',
        username: 'zhangsan',
        port: 53318,
        networkInterface: 'Wi-Fi|192.168.0.5',
        discoveryMode: DiscoveryMode.scan,
        scanIntervalSeconds: 60,
        minimizeToTray: false,
        silentStart: true,
        floatingBall: true,
        ballShowDelayMs: 800,
        ballPosX: 6304,
        ballPosY: 1736,
        ballSnapped: true,
        ballEdge: 1,
        updateCheckHours: 168,
        lastUpdateCheckMs: 1793472000000,
      );

      final WispSettings restored = WispSettings.fromJson(original.toJson());

      expect(restored.username, 'zhangsan');
      expect(restored.port, 53318);
      expect(restored.networkInterface, 'Wi-Fi|192.168.0.5');
      expect(restored.discoveryMode, DiscoveryMode.scan);
      expect(restored.scanIntervalSeconds, 60);
      expect(restored.minimizeToTray, isFalse);
      expect(restored.silentStart, isTrue);
      expect(restored.floatingBall, isTrue);
      expect(restored.ballShowDelayMs, 800);
      expect(restored.ballPosX, 6304);
      expect(restored.ballPosY, 1736);
      expect(restored.ballSnapped, isTrue);
      expect(restored.ballEdge, 1);
      expect(restored.hasUsername, isTrue);
      expect(restored.updateCheckHours, 168);
      expect(restored.lastUpdateCheckMs, 1793472000000);
    });

    test('老版本落盘的数据能平滑升级', () {
      // 老版本只有这几个字段，缺的新字段要各自取到合理默认值。
      final WispSettings restored = WispSettings.fromJson(const <String, dynamic>{
        'alias': '老设备',
        'fingerprint': 'ff00',
        'visible': true,
        'encryption': true,
        'pinEnabled': false,
        'pin': '',
        'autoAccept': false,
        'saveDirectory': null,
        'themeMode': 'system',
        'deviceKind': 'desktop',
      });

      expect(restored.username, isEmpty);
      expect(restored.hasUsername, isFalse);
      expect(restored.port, 53317);
      expect(restored.networkInterface, isNull);
      expect(restored.discoveryMode, DiscoveryMode.auto);
      expect(restored.scanIntervalSeconds, 30);
      expect(restored.minimizeToTray, isTrue);
      // 静默启动是后加的，老数据里没有这一项，默认必须是"照常显示窗口"，
      // 否则升级上来的用户会突然发现点了图标什么也没发生。
      expect(restored.silentStart, isFalse);
      expect(restored.floatingBall, isFalse);
      expect(restored.ballShowDelayMs, 300);
      expect(restored.ballPosX, isNull);
      expect(restored.ballPosY, isNull);
      expect(restored.ballSnapped, isFalse);
      expect(restored.ballEdge, -1);
      // 新字段的默认值：自动检查每天一次、从未检查过。
      expect(restored.updateCheckHours, WispUpdateCadence.defaultHours);
      expect(restored.lastUpdateCheckMs, 0);
    });
  });

  group('静默启动', () {
    test('点开关后落盘，下次读回来还是开着', () async {
      // 这个开关决定原生层要不要显示主窗口，只存在内存里等于没设——
      // 所以断言的重点是"换一个 SettingsService 实例读出来也是 true"。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppState state = AppState();
      state.settings = WispSettings.defaults();

      await state.setSilentStart(true);

      expect(state.settings.silentStart, isTrue);
      final WispSettings restored = await SettingsService().load();
      expect(restored.silentStart, isTrue);
    });

    test('默认不静默，否则首次安装会以为应用没启动', () async {
      expect(WispSettings.defaults().silentStart, isFalse);
      expect(const WispSettings(alias: 'a', fingerprint: 'f').silentStart, isFalse);
    });
  });

  group('发现方式', () {
    test('auto 两条路都走，multicast 只走组播，scan 只走扫描', () {
      expect(DiscoveryMode.auto.multicastEnabled, isTrue);
      expect(DiscoveryMode.auto.scanEnabled, isTrue);
      expect(DiscoveryMode.multicast.multicastEnabled, isTrue);
      expect(DiscoveryMode.multicast.scanEnabled, isFalse);
      expect(DiscoveryMode.scan.multicastEnabled, isFalse);
      expect(DiscoveryMode.scan.scanEnabled, isTrue);
    });

    test('无法识别的值回落到 auto', () {
      expect(DiscoveryMode.parse('不存在的值'), DiscoveryMode.auto);
      expect(DiscoveryMode.parse(null), DiscoveryMode.auto);
      expect(DiscoveryMode.parse('scan'), DiscoveryMode.scan);
    });
  });

  group('识别用户名', () {
    WispDevice deviceWith(String username) => WispDevice(
          alias: '对端',
          ip: '192.168.0.9',
          fingerprint: 'fp-$username',
          username: username,
        );

    test('设置用户名后，只留下同名设备', () async {
      final AppState state = AppState();
      state.settings = const WispSettings(
        alias: '我',
        fingerprint: 'me',
        username: 'zhangsan',
      );

      state.acceptDeviceForTest(deviceWith('zhangsan'));
      state.acceptDeviceForTest(deviceWith('lisi'));
      state.acceptDeviceForTest(deviceWith(''));

      expect(state.devices.length, 1);
      expect(state.devices.first.username, 'zhangsan');
      expect(state.hiddenByUsername, 2);
    });

    test('不设置用户名时，只显示同样没设的设备', () async {
      // 规则是"同名才互相可见"：空对空算同名，空对非空算不同。
      // 否则设了用户名的人就藏不住了——没设的人照样能看见他。
      final AppState state = AppState();
      state.settings = const WispSettings(alias: '我', fingerprint: 'me');

      state.acceptDeviceForTest(deviceWith('zhangsan'));
      state.acceptDeviceForTest(deviceWith('lisi'));
      state.acceptDeviceForTest(deviceWith(''));

      expect(state.devices.length, 1);
      expect(state.devices.first.username, isEmpty);
      expect(state.hiddenByUsername, 2);
    });

    test('大小写与首尾空格不影响匹配', () async {
      final AppState state = AppState();
      state.settings = const WispSettings(
        alias: '我',
        fingerprint: 'me',
        username: 'ZhangSan',
      );

      state.acceptDeviceForTest(deviceWith(' zhangsan '));
      state.acceptDeviceForTest(deviceWith('ZHANGSAN'));
      state.acceptDeviceForTest(deviceWith('lisi'));

      expect(state.devices.length, 2);
      expect(state.hiddenByUsername, 1);
    });

    test('自己不会被当成设备', () async {
      final AppState state = AppState();
      state.settings = const WispSettings(alias: '我', fingerprint: 'me');

      state.acceptDeviceForTest(
        WispDevice(alias: '我', ip: '192.168.0.1', fingerprint: 'me'),
      );

      expect(state.devices, isEmpty);
    });
  });

  group('设备模型', () {
    test('username 是扩展字段，官方客户端没有也能解析', () {
      final WispDevice device = WispDevice.fromJson(
        <String, dynamic>{
          'alias': '官方客户端',
          'fingerprint': 'abcd',
          'port': 53317,
          'protocol': 'https',
        },
        ip: '192.168.0.2',
      );
      expect(device.username, isEmpty);
      expect(device.https, isTrue);
      expect(device.port, 53317);
    });

    test('带 username 的设备能读出来', () {
      final WispDevice device = WispDevice.fromJson(
        <String, dynamic>{'alias': 'A', 'username': 'zhangsan'},
        ip: '192.168.0.3',
      );
      expect(device.username, 'zhangsan');
    });
  });
}
