import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/services/desktop_service.dart';
import 'package:wisp/services/launch_at_login.dart';
import 'package:wisp/state/app_state.dart';

/// 开机启动：一个"看起来开了、下次却没启动"的开关比没有更糟。
///
/// 这一版的三条规矩在这里逐条钉死：
/// 1. 状态回查系统，不存本地记忆；
/// 2. 只认指向当前安装的条目，别被另一份 Wisp 留下的文件骗到；
/// 3. 写完还要再查一次，原生层说"成功"不算数。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String fakeExecutable = '/opt/Wisp App/wisp';
  late Directory temp;
  late File desktopFile;

  void mockChannel(
      Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('wisp/desktop'), handler);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('wisp_autostart_');
    desktopFile = File('${temp.path}/autostart/wisp.desktop');
    LaunchAtLogin.debugSetLinuxEnvironment(
        configDir: temp.path, executable: fakeExecutable);
    DesktopService.debugSetDesktopPlatform(DesktopPlatform.linux);
  });

  tearDown(() async {
    mockChannel(null);
    DesktopService.debugSetDesktopPlatform(null);
    LaunchAtLogin.debugReset();
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // Linux：XDG autostart
  // ---------------------------------------------------------------------------

  test('Linux 初始没有 desktop 文件：支持，但未开启', () async {
    final LaunchAtLoginState state = await LaunchAtLogin.status();
    expect(state.supported, isTrue);
    expect(state.enabled, isFalse);
  });

  test('Linux 开启后写出规范的 desktop 文件，路径带空格要加引号', () async {
    expect(await LaunchAtLogin.set(true), isTrue);
    expect(desktopFile.existsSync(), isTrue);

    final String text = desktopFile.readAsStringSync();
    expect(text, contains('[Desktop Entry]'));
    expect(text, contains('Type=Application'));
    expect(text, contains('Exec="$fakeExecutable"'),
        reason: '路径含空格不加引号，开机启动会直接失败');
    expect(text, contains('X-GNOME-Autostart-enabled=true'));

    expect((await LaunchAtLogin.status()).enabled, isTrue);
  });

  test('Linux 关闭删掉文件；重复关闭也是成功（幂等）', () async {
    await LaunchAtLogin.set(true);
    expect(await LaunchAtLogin.set(false), isTrue);
    expect(desktopFile.existsSync(), isFalse);
    expect((await LaunchAtLogin.status()).enabled, isFalse);

    expect(await LaunchAtLogin.set(false), isTrue);
  });

  test('系统设置里禁用登录项：文件还在，但状态必须判为未开启', () async {
    await LaunchAtLogin.set(true);
    for (final String disabledLine in <String>[
      'Hidden=true',
      'X-GNOME-Autostart-enabled=false',
    ]) {
      desktopFile.writeAsStringSync(
          '${desktopFile.readAsStringSync()}$disabledLine\n');
      expect((await LaunchAtLogin.status()).enabled, isFalse,
          reason: '$disabledLine 表示用户/系统已经禁用了这个登录项');
      // 用户重新打开时要能覆盖掉这两行，而不是永远卡在"关不掉"。
      expect(await LaunchAtLogin.set(true), isTrue);
      expect((await LaunchAtLogin.status()).enabled, isTrue);
    }
  });

  test('另一份 Wisp 留下的文件不该让本机的开关显示已开启', () async {
    desktopFile.parent.createSync(recursive: true);
    desktopFile.writeAsStringSync(
      '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=Wisp\n'
      'Exec="/some/other/install/wisp"\n'
      'X-GNOME-Autostart-enabled=true\n',
    );

    expect((await LaunchAtLogin.status()).enabled, isFalse,
        reason: 'Exec 指向别的安装，这一份根本不会开机启动');
    // 打开时要覆盖成自己的路径。
    expect(await LaunchAtLogin.set(true), isTrue);
    expect(desktopFile.readAsStringSync(), contains(fakeExecutable));
  });

  test('拿不到 XDG 配置目录时声明不支持，而不是往根目录乱写', () async {
    LaunchAtLogin.debugSetLinuxEnvironment(
        configDir: '', executable: fakeExecutable);
    final LaunchAtLoginState state = await LaunchAtLogin.status();
    expect(state.supported, isFalse);
    expect(await LaunchAtLogin.set(true), isFalse);
  });

  // ---------------------------------------------------------------------------
  // 原生通道（Windows / macOS）
  // ---------------------------------------------------------------------------

  test('Windows/macOS：状态与设置都原样转发给原生层', () async {
    DesktopService.debugSetDesktopPlatform(DesktopPlatform.windows);
    final List<MethodCall> calls = <MethodCall>[];
    mockChannel((MethodCall call) async {
      calls.add(call);
      if (call.method == 'launchAtLoginStatus') {
        return <String, Object?>{'supported': true, 'enabled': true};
      }
      if (call.method == 'setLaunchAtLogin') {
        return (call.arguments as Map<Object?, Object?>)['enabled'] == false;
      }
      return null;
    });

    final LaunchAtLoginState state = await LaunchAtLogin.status();
    expect(state.supported, isTrue);
    expect(state.enabled, isTrue);

    expect(await LaunchAtLogin.set(false), isTrue);
    expect(calls.map((MethodCall c) => c.method), <String>[
      'launchAtLoginStatus',
      'setLaunchAtLogin',
    ]);
  });

  test('原生层说不 supported 时，设置页会拿到 unsupported', () async {
    DesktopService.debugSetDesktopPlatform(DesktopPlatform.macos);
    mockChannel((MethodCall call) async {
      if (call.method == 'launchAtLoginStatus') {
        return <String, Object?>{'supported': false, 'enabled': false};
      }
      return null;
    });
    expect((await LaunchAtLogin.status()).supported, isFalse);
  });

  test('通道没实现：unsupported，不是"已开启"', () async {
    DesktopService.debugSetDesktopPlatform(DesktopPlatform.windows);
    mockChannel((MethodCall call) async => null);
    final LaunchAtLoginState state = await LaunchAtLogin.status();
    expect(state.supported, isFalse);
    expect(state.enabled, isFalse);
  });

  test('移动端不显示这个能力', () async {
    DesktopService.debugSetDesktopPlatform(DesktopPlatform.mobile);
    final LaunchAtLoginState state = await LaunchAtLogin.status();
    expect(state.supported, isFalse);
    expect(await LaunchAtLogin.set(true), isFalse);
  });

  // ---------------------------------------------------------------------------
  // AppState：写完不信"成功"，要回查
  // ---------------------------------------------------------------------------

  test('AppState：原生说写成功但回查仍是关，必须判定为失败', () async {
    DesktopService.debugSetDesktopPlatform(DesktopPlatform.windows);
    bool reportedEnabled = false;
    mockChannel((MethodCall call) async {
      if (call.method == 'launchAtLoginStatus') {
        return <String, Object?>{'supported': true, 'enabled': reportedEnabled};
      }
      if (call.method == 'setLaunchAtLogin') {
        // 故意只回 true、不改真实状态，模拟被系统/安全软件挡下来的情况。
        return true;
      }
      return null;
    });

    final AppState state = AppState();
    expect(state.launchAtLoginSupported, isTrue);
    expect(await state.setLaunchAtLogin(true), isFalse,
        reason: '不能把"调用没报错"当成"开机真的会启动"');
    expect(state.launchAtLoginEnabled, isFalse);
    expect(state.launchAtLoginBusy, isFalse, reason: '失败后也要解除忙碌态');

    reportedEnabled = true;
    expect(await state.setLaunchAtLogin(true), isTrue);
    expect(state.launchAtLoginEnabled, isTrue);
  });
}
