import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「更新装完自动重启」的护栏。
///
/// 这条链路没有任何编译器能帮忙检查，而且坏掉时**完全静默**：
/// · Inno Setup 的 /SILENT 不显示完成页，带 `postinstall` 标志的启动项在静默
///   安装时根本不会执行——之前就是这么把自动重启丢掉的，表现出来只是"更新完
///   应用没了"，没有任何报错；
/// · macOS 直接 `cp -R src.app /Applications/` 时，若目标已存在，BSD cp 会把
///   新包塞进旧包内部（X.app/X.app），替换后主程序仍是旧版本，用户会以为
///   "更新没生效"，而且照样没有报错。
///
/// 这两处都只能靠读脚本/源码断言来守，所以固化在这里。
void main() {
  group('Windows 安装器', () {
    late String iss;

    setUpAll(() {
      iss = File('packaging/windows/wisp.iss').readAsStringSync();
    });

    test('静默安装后必须自动拉起新版', () {
      // 静默分支靠 WizardSilent 判断，不能用 postinstall。
      final RegExp silentEntry = RegExp(
        r'Filename:\s*"\{app\}\\wisp\.exe"[^\n]*Check:\s*WizardSilent',
      );
      expect(silentEntry.hasMatch(iss), isTrue,
          reason: '没有 WizardSilent 的启动项：应用内一键更新装完不会自动重启');

      // 交互分支必须 skipifsilent，否则静默时会跑两遍、两个实例抢同一个端口。
      final RegExp interactiveEntry = RegExp(
        r'Filename:\s*"\{app\}\\wisp\.exe"[^\n]*postinstall[^\n]*skipifsilent',
      );
      expect(interactiveEntry.hasMatch(iss), isTrue,
          reason: '交互安装的启动项缺少 postinstall + skipifsilent 组合');

      // 提权后的 setup 拉起应用时必须降回普通用户权限。
      expect(iss, contains('runasoriginaluser'),
          reason: '更新后拉起的 Wisp 会带着管理员权限运行');
    });

    test('静默安装前必须强关旧实例', () {
      // Wisp 收到 WM_CLOSE 是缩到托盘而不是退出，Restart Manager 关不掉它，
      // wisp.exe 会一直占着文件，静默安装随后失败或只更新一半。
      expect(iss, contains('taskkill.exe'),
          reason: '没有强关旧实例：旧进程占着 wisp.exe，静默安装会失败');
      expect(iss, contains('ssInstall'),
          reason: '必须在拷贝文件之前（ssInstall）关掉旧进程');
      expect(iss, contains('/F /IM wisp.exe'));
    });
  });

  group('macOS 安装器', () {
    late String source;

    setUpAll(() {
      source = File('lib/services/update_installer.dart').readAsStringSync();
    });

    test('不能直接 cp 进 /Applications（会嵌套成 X.app/X.app）', () {
      expect(source, isNot(contains("'/Applications/'")),
          reason: '直接拷进 /Applications 目录时，目标已存在会把新包塞进旧包内部');
      // 必须走"暂存 -> 删旧 -> 改名"的整体替换。
      expect(source, contains('.incoming'));
      expect(source, contains('restartPath: target'),
          reason: '装完没有把重启路径交出去，macOS 更新后不会自动重启');
    });

    test('重启前要等本进程退出，否则新旧实例抢端口', () {
      expect(source, contains(r'exec /usr/bin/open -n "$1"'),
          reason: '重启必须交给延迟执行的子 shell，且路径走位置参数避免转义问题');
      expect(source, contains('ProcessStartMode.detached'),
          reason: '重启子进程必须脱离父进程，否则会跟着本进程一起退出');
    });
  });
}
