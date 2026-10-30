import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// 内置自签证书的唯一入口：接收端建 TLS 上下文、设置页显示指纹，都从这里取。
///
/// 为什么集中一处：证书是"加密能不能用"和"指纹显示得对不对"的共同前提，
/// 两边各读一份 assets 迟早会出现"开关显示已启用、实际还在明文"的错位。
class WispTls {
  const WispTls._();

  static const String certAsset = 'assets/certs/cert.pem';
  static const String keyAsset = 'assets/certs/key.pem';

  static Uint8List? _pemBytes;
  static String? _fingerprint;

  static Future<Uint8List?> _load(String asset) async {
    try {
      final ByteData data = await rootBundle.load(asset);
      return data.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  /// 证书的 DER 部分（PEM 去掉头尾与换行后 base64 解码）。
  static Future<Uint8List?> certificateDer() async {
    final Uint8List? pem = _pemBytes ?? await _load(certAsset);
    if (pem == null) return null;
    _pemBytes = pem;
    try {
      final String body = utf8
          .decode(pem)
          .split('\n')
          .where((String line) => !line.startsWith('-----') && line.trim().isNotEmpty)
          .join();
      return base64Decode(body);
    } catch (_) {
      return null;
    }
  }

  /// SHA-256 指纹，形如 `F0:08:2B:…:B0`。
  ///
  /// 与 `openssl x509 -fingerprint -sha256` 的输出格式一致，
  /// 两端要对指纹时直接照着念即可。
  static Future<String?> fingerprint() async {
    final String? cached = _fingerprint;
    if (cached != null) return cached;
    final Uint8List? der = await certificateDer();
    if (der == null) return null;
    final String hex = sha256.convert(der).toString().toUpperCase();
    final List<String> pairs = <String>[];
    for (int i = 0; i + 1 < hex.length; i += 2) {
      pairs.add(hex.substring(i, i + 2));
    }
    _fingerprint = pairs.join(':');
    return _fingerprint;
  }

  /// 接收端用的 TLS 上下文。证书缺失或私钥不匹配时返回 null，
  /// 调用方据此退回明文 HTTP（设置页会如实显示，不假装安全）。
  static Future<SecurityContext?> context() async {
    final Uint8List? cert = await _load(certAsset);
    final Uint8List? key = await _load(keyAsset);
    if (cert == null || key == null) return null;
    try {
      final SecurityContext context = SecurityContext(withTrustedRoots: false);
      context.useCertificateChainBytes(cert);
      context.usePrivateKeyBytes(key);
      return context;
    } catch (_) {
      return null;
    }
  }
}
