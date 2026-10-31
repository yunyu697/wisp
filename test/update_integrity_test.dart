// 一键更新的完整性校验：清单给了 sha256 就必须逐字节对上。
//
// 背景：`download()` 原本下完直接交给安装器提权运行，而下载源包含三个第三方
// 加速代理——任何一个被投毒就是"用户点一下、以管理员身份装了个木马"。
// 现在：清单带 sha256（CI 发版时生成），对不上就删包换源；没带摘要就拒绝自动安装。
//
// 这里刻意不初始化 widget binding：一旦初始化，主 isolate 的 HttpClient 会被
// 换成"一律 400"的桩，真实下载就测不了了。
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/services/update_installer.dart';
import 'package:wisp/services/update_service.dart';

void main() {
  late HttpServer server;
  late List<int> payload;
  late int hits;
  late String url;

  setUp(() async {
    hits = 0;
    payload = List<int>.generate(64 * 1024, (int i) => (i * 11) % 251);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      hits++;
      request.response
        ..statusCode = 200
        ..headers.contentLength = payload.length
        ..add(payload);
      await request.response.close();
    });
    url = 'http://127.0.0.1:${server.port}/wisp-integrity.exe';
  });

  tearDown(() async => server.close(force: true));

  WispUpdateInfo manifestWith(String? digest) => WispUpdateInfo(
        latestVersion: '9.9.9',
        downloads: <String, String>{platformKey: url},
        sha256: digest == null ? const <String, String>{} : <String, String>{platformKey: digest},
      );

  test('清单里的摘要与解析一致', () {
    final WispUpdateInfo info = WispUpdateInfo.fromJson(<String, dynamic>{
      'version': '9.9.9',
      'downloads': <String, dynamic>{platformKey: url},
      'sha256': <String, dynamic>{platformKey: 'ABCDEF'},
    });
    expect(info.expectedSha256, 'abcdef', reason: '摘要统一转小写再比');
    expect(WispUpdateInfo.fromJson(<String, dynamic>{'version': '9.9.9'}).expectedSha256, isNull);
  });

  test('摘要一致：下载成功并落盘', () async {
    final String digest = sha256.convert(payload).toString();
    final String path = await WispUpdateInstaller.download(
      info: manifestWith(digest),
    );
    addTearDown(() async {
      final File f = File(path);
      if (await f.exists()) await f.delete();
    });
    expect(await WispUpdateInstaller.sha256OfFile(path), digest);
    expect((await File(path).readAsBytes()).length, payload.length);
    expect(hits, 1);
  });

  test('摘要不符：拒绝使用，且不把坏包留在磁盘上', () async {
    final File leftover = File(
      '${WispUpdateInstaller.downloadDir().path}${Platform.pathSeparator}wisp-integrity.exe',
    );
    if (await leftover.exists()) await leftover.delete();

    Object? error;
    try {
      await WispUpdateInstaller.download(info: manifestWith('0' * 64));
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull, reason: '摘要不符竟然通过了');
    expect('$error', contains('校验失败'), reason: '$error');
    expect(await leftover.exists(), isFalse, reason: '被篡改的安装包不能留在磁盘上');
    expect(hits, greaterThanOrEqualTo(1), reason: '应当真的下过一次才发现摘要不符');
  });

  test('清单没有摘要：自动安装直接拒绝，一个字节都不下', () async {
    Object? error;
    try {
      await WispUpdateInstaller.download(info: manifestWith(null));
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull);
    expect('$error', contains('没有提供校验值'), reason: '$error');
    expect(hits, 0, reason: '既然不允许装，就不该浪费用户流量');
  });

  test('清单没有摘要 + 仅下载模式：允许下载，供用户手动安装', () async {
    final String path = await WispUpdateInstaller.download(
      info: manifestWith(null),
      requireVerified: false,
    );
    addTearDown(() async {
      final File f = File(path);
      if (await f.exists()) await f.delete();
    });
    expect(await File(path).exists(), isTrue);
    expect((await File(path).length()), payload.length);
  });

  test('sha256OfFile 与 crypto 算出来的一致', () async {
    final Directory dir = await Directory.systemTemp.createTemp('wisp-digest');
    addTearDown(() => dir.delete(recursive: true));
    final File f = File('${dir.path}${Platform.pathSeparator}blob.bin');
    final List<int> bytes = List<int>.generate(4096, (int i) => i % 256);
    await f.writeAsBytes(bytes);
    expect(await WispUpdateInstaller.sha256OfFile(f.path), sha256.convert(bytes).toString());
  });
}
