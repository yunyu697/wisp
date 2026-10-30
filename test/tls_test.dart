import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/services/tls_service.dart';

/// 加密开关能不能真的起作用，取决于 two things：证书读得到、私钥与证书配对。
/// 这组测试在测试环境里真读 assets/certs，任何一项缺失/写错都会立刻失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('证书能读出 DER', () async {
    final List<int>? der = await WispTls.certificateDer();
    expect(der, isNotNull);
    expect(der!.length, greaterThan(300));
    // DER 的 SEQUENCE 标签 + 长度，防止把 base64 解错却看起来"有内容"。
    expect(der.first, 0x30);
  });

  test('指纹是 32 组大写十六进制', () async {
    final String? fp = await WispTls.fingerprint();
    expect(fp, isNotNull);
    final List<String> pairs = fp!.split(':');
    expect(pairs.length, 32);
    for (final String pair in pairs) {
      expect(RegExp(r'^[0-9A-F]{2}$').hasMatch(pair), isTrue);
    }
  });

  test('TLS 上下文能建起来（私钥与证书匹配）', () async {
    final SecurityContext? context = await WispTls.context();
    expect(context, isNotNull);
  });
}
