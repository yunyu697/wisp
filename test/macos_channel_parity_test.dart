import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守住 Dart ↔ macOS 原生层的通道契约。
///
/// 背景：macOS 侧曾经**完全没有**实现通知卡/悬浮球这些方法，Dart 调用会
/// 收到 `FlutterMethodNotImplemented` 然后被 `catch` 静默吞掉——界面上什么
/// 都不发生，日志里什么都没有，用户只能看到"点了没反应"。这类问题在运行时
/// 测不出来（回归测试跑在 Linux/Windows 上），所以这里直接在源码层面比对：
///
/// * Dart 侧调用的每个方法，要么在 Swift 的 `case` 里，要么在
///   [windowsOnly] 里被显式认定为"Windows 专有、macOS 上开关是隐藏的"；
/// * Dart 侧监听的每个事件，Swift 侧必须真的会发出来。
void main() {
  final File service = File('lib/services/desktop_service.dart');
  final File mainWindow = File('macos/Runner/MainFlutterWindow.swift');
  final File overlay = File('macos/Runner/WispOverlay.swift');
  final File dropView = File('macos/Runner/WispDropView.swift');
  final File pbxproj = File('macos/Runner.xcodeproj/project.pbxproj');
  final File windowsRunner = File('windows/runner/flutter_window.cpp');
  final File launchSwift = File('macos/Runner/WispLaunchAtLogin.swift');
  final File launchDart = File('lib/services/launch_at_login.dart');

  /// 只有 Windows 实现、且 macOS 设置页已经隐藏了对应开关的能力。
  /// 加进来的每一项都必须说清楚为什么不用跨平台。
  const Map<String, String> windowsOnly = <String, String>{
    'setMinimizeToTray': 'macOS 关窗驻留菜单栏，没有托盘最小化这个开关',
    'setStartupVisible': 'macOS 没有静默启动开关',
    'serviceStatus': 'Windows 服务（SCM）专有',
    'installService': 'Windows 服务（SCM）专有',
    'restartService': 'Windows 服务（SCM）专有',
    'uninstallService': 'Windows 服务（SCM）专有',
    'runInstaller': '一键更新在 macOS 走自己的 AppKit 安装流程',
    'debugCapture': '像素抓取基于 GDI BitBlt，仅 Windows 自测用',
    'debugFocusMain': '焦点模拟仅 Windows 自测用',
    'debugBlurMain': '焦点模拟仅 Windows 自测用',
  };

  /// Dart 侧监听的原生事件。少发一个，对应的交互就哑掉。
  const List<String> events = <String>[
    'onBallClicked',
    'onBallPosition',
    'onBubbleAction',
    'onBubbleTimeout',
    'onFilesDropped',
    'onToastClicked',
    'onWindowVisibility',
    'onWindowRestored',
  ];

  /// 已知缺口：Dart 在监听，但 macOS 原生层还不发。
  ///
  /// 留在这里而不是从断言里删掉：缺口是"已知"的，不是"忘了"的。
  /// 目前没有——`onFilesDropped` 已随 WispDropView 补齐。将来再出现
  /// 新的缺口，记到这里，补上时测试会失败并提醒删除记录。
  const Map<String, String> missingEvents = <String, String>{};

  bool skip(File file) {
    if (!file.existsSync()) {
      // 不在完整仓库里跑（比如只拷了 lib/）：这条测试没有意义，跳过。
      markTestSkipped('找不到 ${file.path}');
      return true;
    }
    return false;
  }

  test('Dart 调用的每个桌面方法，macOS 原生层都要有对应分支', () {
    if (skip(mainWindow) || skip(service)) return;

    final RegExp call = RegExp(r"invokeMethod[^(]*\(\s*'([a-zA-Z]+)'");
    final Set<String> used = <String>{
      for (final RegExpMatch m in call.allMatches(service.readAsStringSync()))
        m.group(1)!,
    };

    final RegExp branch = RegExp(r'case "([a-zA-Z]+)"');
    final Set<String> implemented = <String>{
      for (final RegExpMatch m in branch.allMatches(mainWindow.readAsStringSync()))
        m.group(1)!,
    };

    final List<String> missing = used
        .where((String name) =>
            !implemented.contains(name) && !windowsOnly.containsKey(name))
        .toList()
      ..sort();

    expect(
      missing,
      isEmpty,
      reason: '这些方法 Dart 会调用，但 macOS 的 wisp/desktop 通道里没有分支：'
          '${missing.join('、')}。要么在 MainFlutterWindow.swift 里补上，'
          '要么加进本测试的 windowsOnly 并说明原因。',
    );
  });

  test('Dart 监听的事件，macOS 侧必须真的会发出来', () {
    if (skip(mainWindow) || skip(overlay)) return;

    final String source =
        mainWindow.readAsStringSync() + overlay.readAsStringSync();
    final List<String> missing = events
        .where((String name) => !source.contains('"$name"'))
        .toList();

    expect(missing, isEmpty,
        reason: '这些事件 Dart 在监听，但 macOS 原生层从来不发：${missing.join('、')}');
    // 已知缺口必须仍然是真的缺口：等哪天补上了，这里会失败并提醒删掉记录。
    for (final MapEntry<String, String> gap in missingEvents.entries) {
      expect(source.contains('"${gap.key}"'), isFalse,
          reason: '${gap.key} 已经实现了，把 missingEvents 里那条记录删掉');
    }
  });

  test('浮层状态接口存在，否则 Dart 的重发闭环会永远判失败', () {
    if (skip(overlay)) return;
    final String source = overlay.readAsStringSync();
    // _desktopNotice 靠 surfaceStatus 的 visible+drawn 判断"到底画出来没有"。
    // 少一个字段，Dart 就会每次都认为失败、连发两次再放弃。
    expect(source.contains('"visible"'), isTrue);
    expect(source.contains('"drawn"'), isTrue);
    expect(source.contains('surfaceStatus'), isTrue);
  });

  test('拖拽层必须让指针事件穿透，否则主界面整块点不动', () {
    if (skip(dropView)) return;
    final String source = dropView.readAsStringSync();

    // 拖拽派发不走 hitTest，鼠标事件走。所以"盖在上面还能收拖拽、不挡点击"
    // 的唯一支点就是 hitTest 直接返回 nil。
    //
    // 一旦有人改成 super.hitTest(...)，拖拽看上去仍然正常，主界面却变成一张
    // 点不动的图——坏得不彻底、又全都在主路径上，必须在提交前挡住。
    final RegExp passthrough = RegExp(
        r'override func hitTest\([^)]*\)\s*->\s*NSView\?\s*\{\s*nil\s*\}');
    expect(passthrough.hasMatch(source), isTrue,
        reason: 'WispDropView.hitTest 必须直接返回 nil：它盖在 FlutterView 上，'
            '一旦参与 hitTest 就会吞掉主界面的所有点击、滚动与悬停');

    // 没注册拖拽类型，draggingEntered 永远不会被调用。
    expect(source.contains('registerForDraggedTypes'), isTrue);

    // 接住拖拽却从不回调 = 把用户拖进来的文件静默丢掉。
    expect(source.contains('onDrop?('), isTrue,
        reason: 'performDragOperation 必须真的把路径交回 Dart');
  });

  test('新增的原生文件必须真的进了编译列表', () {
    if (skip(pbxproj)) return;
    final String source = pbxproj.readAsStringSync();
    for (final String name in <String>[
      'WispOverlay.swift',
      'WispDropView.swift',
      'WispLaunchAtLogin.swift',
    ]) {
      expect(source.contains('$name in Sources'), isTrue,
          reason: '$name 没进 Runner target 的 Compile Sources：文件写了、'
              '测试也绿了，但应用里根本没有这段代码');
    }
  });

  test('开机启动：三个桌面平台都要有真实实现，且都回查系统状态', () {
    if (skip(windowsRunner) || skip(mainWindow) || skip(launchSwift) ||
        skip(launchDart)) {
      return;
    }
    final String cpp = windowsRunner.readAsStringSync();
    final String swift = mainWindow.readAsStringSync();
    final String swiftImpl = launchSwift.readAsStringSync();
    final String dart = launchDart.readAsStringSync();

    // 这个功能是三端各写一遍的，最容易出现的回归是"只改了 Dart、
    // 忘了某一端原生层"——Dart 侧 catch 掉异常后界面毫无反应。
    for (final String method in <String>[
      'launchAtLoginStatus',
      'setLaunchAtLogin',
    ]) {
      expect(cpp.contains('name == "$method"'), isTrue,
          reason: 'Windows runner 少了 $method 分支');
      expect(swift.contains('case "$method"'), isTrue,
          reason: 'macOS runner 少了 $method 分支');
    }

    // Linux 是纯 Dart 的 XDG autostart，不接原生通道。
    expect(dart.contains('autostart'), isTrue);
    expect(dart.contains('APPIMAGE'), isTrue,
        reason: 'AppImage 的 /proc/self/exe 指向临时挂载目录，'
            '写进 autostart 下次开机必然失效');

    // 三条实现都必须"写完回查"，不能把"没抛异常"当成已开启。
    expect(cpp.contains('ReadAutoStart() == enabled'), isTrue,
        reason: 'Windows 写完必须回读注册表');
    expect(swiftImpl.contains('status()["enabled"]'), isTrue,
        reason: 'macOS 关掉后必须回查 SMAppService / LaunchAgent');
    expect(dart.contains('_linuxEnabled()'), isTrue,
        reason: 'Linux 状态必须读 desktop 文件，不能记在本地');
  });
}
