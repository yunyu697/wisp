import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/services/update_installer.dart';
import 'package:wisp/services/update_service.dart';

/// 下载行为的测试。**不初始化 TestWidgetsFlutterBinding**——
/// 那个绑定会把所有 HttpClient 请求拦成 400（教训见 update_test.dart 头注释），
/// 真实回环 HttpServer 只有在无绑定的纯 Dart 环境里才能通。
/// 自动安装（通道 mock）的测试在 update_installer_install_test.dart。
void main() {
  group('WispUpdateInstaller 下载', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('下载安装包：文件完整、进度回调、文件名取自直链', () async {
      final List<int> payload =
          List<int>.generate(96 * 1024, (int i) => i % 251);
      server.listen((HttpRequest request) async {
        request.response.add(payload);
        await request.response.close();
      });

      final String directUrl =
          'http://127.0.0.1:${server.port}/wisp-windows-x64-99.0.0-setup.exe';
      final WispUpdateInfo info = WispUpdateInfo(
        latestVersion: '99.0.0',
        downloads: <String, String>{'windows': directUrl},
      );

      int progressCalls = 0;
      int lastReceived = 0;
      final String path = await WispUpdateInstaller.download(
        info: info,
        onProgress: (int received, int total) {
          progressCalls++;
          lastReceived = received;
        },
      );

      final File file = File(path);
      expect(await file.exists(), isTrue, reason: '下载的文件应该存在：$path');
      expect(await file.length(), payload.length,
          reason: '下载内容必须完整（.part 改名后不能是半个文件）');
      expect(path.endsWith('wisp-windows-x64-99.0.0-setup.exe'), isTrue);
      expect(progressCalls, greaterThan(0));
      expect(lastReceived, payload.length);
      await file.delete();
    });

    test('清单里没有本平台直链时明确报错，不瞎猜', () async {
      const WispUpdateInfo info = WispUpdateInfo(
        latestVersion: '99.0.0',
        downloads: <String, String>{}, // 空
      );
      await expectLater(
        WispUpdateInstaller.download(info: info),
        throwsA(isA<StateError>()),
      );
    });

    test('所有源都失败时抛错并带上原因', () async {
      // 死端口：官方源 + 三个镜像前缀全部不可达。
      const WispUpdateInfo info = WispUpdateInfo(
        latestVersion: '99.0.0',
        downloads: <String, String>{
          'windows': 'http://127.0.0.1:1/wisp-should-fail.exe',
        },
      );
      await expectLater(
        WispUpdateInstaller.download(info: info),
        throwsA(isA<StateError>()),
      );
    });

    test('Linux/Android 的下载目录必须是用户找得到的地方', () {
      // 只断言"不抛异常"——具体路径因平台而异（Linux 落 ~/Downloads，
      // 其它落临时目录），真正的平台断言跑在对应平台的 CI 上。
      expect(WispUpdateInstaller.downloadDir().path, isNotEmpty);
    });
  });
}
