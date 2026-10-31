import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/services/update_installer.dart';

/// 自动安装（平台通道）的测试。
///
/// 需要 MethodChannel mock（TestDefaultBinaryMessengerBinding），
/// 所以单独成一个文件——下载行为的测试不能用这个 binding（会把
/// HttpClient 全拦成 400），见 update_installer_test.dart 头注释。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ChannelStub stub;

  setUp(() {
    stub = _ChannelStub();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('wisp/desktop'), stub.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('wisp/desktop'), null);
  });

  test('Windows：runInstaller 成功即返回 ok，并带上静默参数', () async {
    if (!Platform.isWindows) return; // 平台分支只在本平台验证，其余 CI 兜底。
    final UpdateInstallOutcome outcome =
        await WispUpdateInstaller.install(r'C:\tmp\wisp-setup.exe');
    expect(outcome.ok, isTrue);
    expect(stub.calls, contains('runInstaller'));
    expect(stub.lastArgs, contains('/SILENT'),
        reason: '自动更新必须静默安装，否则用户要手动点完整个向导');
  });

  test('runInstaller 返回 false 时给出可行动的失败提示', () async {
    if (!Platform.isWindows) return;
    stub.replyFalse = true;
    final UpdateInstallOutcome outcome =
        await WispUpdateInstaller.install(r'C:\tmp\wisp-setup.exe');
    expect(outcome.ok, isFalse);
    expect(outcome.message, contains('手动'));
  });

  test('supportsAutoInstall 与平台一致', () {
    expect(WispUpdateInstaller.supportsAutoInstall,
        Platform.isWindows || Platform.isMacOS);
  });
}

/// 记录通道调用并按脚本应答。
class _ChannelStub {
  final List<String> calls = <String>[];
  bool replyFalse = false;
  String lastArgs = '';

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    if (call.method == 'runInstaller') {
      final Map<Object?, Object?> args =
          (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
      lastArgs = '${args['args']}';
      return !replyFalse;
    }
    return null;
  }
}
