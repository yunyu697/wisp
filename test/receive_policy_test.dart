import 'package:flutter_test/flutter_test.dart';

import 'package:wisp/core/constants.dart';
import 'package:wisp/services/settings_service.dart';

/// 接收策略（免确认白名单）的纯逻辑测试。
///
/// 全程普通 `test()`、不碰网络、不碰 widget binding：shouldAutoAccept 是纯函数，
/// 直接构造 WispSettings 断言判定表即可。
WispSettings _settings({
  ReceivePolicy policy = ReceivePolicy.ask,
  List<String> trusted = const <String>[],
  bool pinEnabled = false,
  String pin = '',
  bool autoAccept = false,
}) =>
    WispSettings(
      alias: 'Receiver',
      fingerprint: 'me',
      receivePolicy: policy,
      trustedFingerprints: trusted,
      pinEnabled: pinEnabled,
      pin: pin,
      autoAccept: autoAccept,
    );

bool _autoAccept(
  WispSettings settings, {
  String fingerprint = 'fp-a',
  int fileCount = 1,
  int totalBytes = 1024,
}) =>
    settings.shouldAutoAccept(
      fingerprint: fingerprint,
      fileCount: fileCount,
      totalBytes: totalBytes,
    );

void main() {
  group('三态判定表', () {
    test('ask 永不自动；all 全收；trusted 只收白名单内的 fingerprint', () {
      expect(_autoAccept(_settings(policy: ReceivePolicy.ask)), isFalse);
      expect(_autoAccept(_settings(policy: ReceivePolicy.all)), isTrue);
      expect(
        _autoAccept(_settings(
          policy: ReceivePolicy.trusted,
          trusted: <String>['fp-a'],
        )),
        isTrue,
      );
      expect(
        _autoAccept(_settings(
          policy: ReceivePolicy.trusted,
          trusted: <String>['fp-b'],
        )),
        isFalse,
      );
    });

    test('默认值是 ask，白名单为空', () {
      const WispSettings defaults =
          WispSettings(alias: 'A', fingerprint: 'f');
      expect(defaults.receivePolicy, ReceivePolicy.ask);
      expect(defaults.trustedFingerprints, isEmpty);
      expect(_autoAccept(defaults), isFalse);
    });
  });

  group('白名单只认 fingerprint', () {
    test('IP / 别名长得再像也不算，只有 fingerprint 命中才放行', () {
      final WispSettings settings = _settings(
        policy: ReceivePolicy.trusted,
        trusted: <String>['fp-a'],
      );
      expect(_autoAccept(settings, fingerprint: '192.168.1.31'), isFalse);
      expect(_autoAccept(settings, fingerprint: 'Tyler 的 iPhone'), isFalse);
      expect(_autoAccept(settings, fingerprint: 'fp-a'), isTrue);
    });
  });

  group('无 fingerprint 的老设备', () {
    test('空 / 全空白的 fingerprint 永不自动，连 all 策略也不放行', () {
      for (final ReceivePolicy policy in ReceivePolicy.values) {
        final WispSettings settings = _settings(
          policy: policy,
          trusted: <String>['', '   '],
        );
        expect(_autoAccept(settings, fingerprint: ''), isFalse,
            reason: '$policy 也不能给无 fingerprint 的设备免确认');
        expect(_autoAccept(settings, fingerprint: '   '), isFalse);
      }
    });
  });

  group('规模护栏', () {
    test('文件数 / 字节数超限回落确认，防止被灌盘', () {
      final WispSettings settings = _settings(policy: ReceivePolicy.all);
      // 恰好等于上限仍放行（护栏是"超过"才拦）。
      expect(
        _autoAccept(settings,
            fileCount: WispProtocol.maxAutoAcceptFiles, totalBytes: 1),
        isTrue,
      );
      expect(
        _autoAccept(settings,
            fileCount: 1, totalBytes: WispProtocol.maxAutoAcceptBytes),
        isTrue,
      );
      expect(
        _autoAccept(settings,
            fileCount: WispProtocol.maxAutoAcceptFiles + 1, totalBytes: 1),
        isFalse,
      );
      expect(
        _autoAccept(settings,
            fileCount: 1,
            totalBytes: WispProtocol.maxAutoAcceptBytes + 1),
        isFalse,
      );
    });
  });

  group('安全边界', () {
    test('PIN 闸门独立生效：shouldAutoAccept 不绕过 pinEnabled', () {
      final WispSettings withPin = _settings(
        policy: ReceivePolicy.all,
        pinEnabled: true,
        pin: '1234',
      );
      // PIN / 用户名范围 / 证书校验在接收端 _handlePrepare 里独立执行，
      // shouldAutoAccept 既读不到也不改写它们：它的结论与开不开 PIN 完全一致。
      // 也就是说"自动接收"只是免确认层，并没有、也不会跳过 pinEnabled 这道闸门。
      expect(withPin.pinEnabled, isTrue);
      expect(withPin.pin, '1234');
      expect(_autoAccept(withPin), _autoAccept(_settings(policy: ReceivePolicy.all)));
    });
  });

  group('老数据升级', () {
    test('autoAccept=true 升级成 all，false 升级成 ask；缺白名单取空', () {
      final WispSettings wasOn = WispSettings.fromJson(const <String, dynamic>{
        'alias': '老设备',
        'fingerprint': 'ff00',
        'autoAccept': true,
      });
      expect(wasOn.receivePolicy, ReceivePolicy.all);
      expect(wasOn.trustedFingerprints, isEmpty);
      expect(_autoAccept(wasOn), isTrue);

      final WispSettings wasOff = WispSettings.fromJson(const <String, dynamic>{
        'alias': '老设备',
        'fingerprint': 'ff00',
        'autoAccept': false,
      });
      expect(wasOff.receivePolicy, ReceivePolicy.ask);
      expect(_autoAccept(wasOff), isFalse);
    });
  });
}
