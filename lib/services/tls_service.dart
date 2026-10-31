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

  // ---------------------------------------------------------------------------
  // 对端证书校验
  //
  // 自签证书没法靠 CA 链验证，只能"证书哈希 == 对端在报文里声明的指纹"。
  // 这就是 LocalSend 的做法：`fingerprint` 是设备信息的一部分，两端各自算
  // 自己证书的 SHA-256，收到请求时互相比对。
  //
  // 不校验会怎样：同网段的任何人出示任意证书都能握手成功，等于把加密降级成
  // "防君子不防小人"——中间人换个证书就能读到全部文件名与内容。
  // ---------------------------------------------------------------------------

  /// 任意证书的紧凑指纹：64 位小写十六进制，与协议里的 `fingerprint` 同格式。
  static String compactFingerprint(X509Certificate cert) =>
      sha256.convert(cert.der).toString().toLowerCase();

  /// 把协议里的指纹归一化：去掉冒号与空白、转小写。
  ///
  /// 官方客户端发的是 64 位小写十六进制；本机设置页展示的是带冒号的大写
  /// （对齐 `openssl x509 -fingerprint -sha256` 的输出），两边都得能比。
  static String normalizeFingerprint(String raw) =>
      raw.replaceAll(RegExp(r'[:\s]'), '').toLowerCase();

  /// 证书是否与对端声明的 [claimed] 指纹一致。
  ///
  /// 返回 null 表示**无法判定**，调用方自己决定是放行还是拒绝，
  /// 别把"不知道"当成"通过"。三种情况返回 null：
  /// 1. 没有证书（走明文 HTTP，或服务端未请求客户端证书）；
  /// 2. 对端没上报指纹；
  /// 3. 上报的**不是证书指纹的形状**。
  ///
  /// 第 3 条是踩过坑才加的：协议 §2 规定"HTTPS 模式下指纹是证书的 SHA-256，
  /// HTTP 模式下是随机串"。Wisp 自己一直上报 32 位随机串（历史实现），
  /// 拿它去比 64 位证书哈希必然不等——1.0.20 因此把每台真实设备都判成
  /// "证书与声明不符"，设备被踢出列表，横幅每隔几秒刷一条。
  /// 现在只对 64 位十六进制的声明做比对，其余一律视为"设备 ID，不是证书声明"。
  static bool? certMatchesClaim(X509Certificate? cert, String? claimed) {
    if (cert == null) return null;
    final String expected = normalizeFingerprint(claimed ?? '');
    if (!_isSha256Hex(expected)) return null;
    return compactFingerprint(cert) == expected;
  }

  /// 是否是 64 位十六进制（SHA-256 的紧凑形式）。
  static bool _isSha256Hex(String value) =>
      value.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
}
