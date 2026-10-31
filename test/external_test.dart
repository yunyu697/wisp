import 'package:flutter_test/flutter_test.dart';

import 'package:wisp/core/utils/external.dart';

/// 打开外链的单元测试。
///
/// 只测纯逻辑（协议校验、失败结果）；真正唤起浏览器要走原生通道，
/// 由 `wisp.exe --wisp-openurl=... --wisp-report=...` 的端到端自测覆盖。
void main() {
  group('协议校验', () {
    test('放行 http 与 https', () {
      expect(isOpenableWebUrl('https://github.com/a/b.exe'), isTrue);
      expect(isOpenableWebUrl('http://github.com/a/b.exe'), isTrue);
    });

    test('大小写不敏感', () {
      expect(isOpenableWebUrl('HTTPS://github.com/a/b.exe'), isTrue);
      expect(isOpenableWebUrl('HtTp://github.com/a/b.exe'), isTrue);
    });

    test('前后空白照常放行', () {
      expect(isOpenableWebUrl('  https://github.com/a/b.exe  '), isTrue);
    });

    test('拦掉非 http(s) 协议', () {
      // file:// 能打开本地可执行文件——绝对不能放行。
      expect(isOpenableWebUrl('file:///C:/Windows/System32/cmd.exe'), isFalse);
      expect(isOpenableWebUrl('javascript:alert(1)'), isFalse);
      expect(isOpenableWebUrl('ftp://example.com/a'), isFalse);
      expect(isOpenableWebUrl('ms-settings:'), isFalse);
    });

    test('空串与纯空白被拦', () {
      expect(isOpenableWebUrl(''), isFalse);
      expect(isOpenableWebUrl('   '), isFalse);
    });

    test('前缀伪装被拦', () {
      // 看着像 https 但协议不是。
      expect(isOpenableWebUrl('https:/example.com'), isFalse);
      expect(isOpenableWebUrl('xhttps://example.com'), isFalse);
    });
  });

  group('失败结果', () {
    test('空链接给出明确原因', () async {
      final ExternalOpenResult result = await openExternal('  ');
      expect(result.opened, isFalse);
      expect(result.message, isNotNull);
      expect(result.message, isNotEmpty);
    });

    test('非 http(s) 链接给出明确原因', () async {
      final ExternalOpenResult result =
          await openExternal('file:///C:/Windows/System32/cmd.exe');
      expect(result.opened, isFalse);
      expect(result.message, contains('http'));
    });

    test('成功结果不带失败原因', () {
      expect(ExternalOpenResult.ok.opened, isTrue);
      expect(ExternalOpenResult.ok.message, isNull);
    });
  });
}
