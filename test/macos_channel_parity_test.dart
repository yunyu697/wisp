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
    'onToastClicked',
    'onWindowVisibility',
    'onWindowRestored',
  ];

  /// 已知缺口：Dart 在监听，但 macOS 原生层还不发。
  ///
  /// 留在这里而不是从断言里删掉：缺口是"已知"的，不是"忘了"的。
  const Map<String, String> missingEvents = <String, String>{
    'onFilesDropped': 'macOS 主窗口还没接文件拖拽。拖放需要自绘 NSView 参与 '
        'NSDraggingDestination，而覆盖在 FlutterView 上的拖拽层会抢走鼠标事件，'
        '风险高，单独一轮处理。',
  };

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
}
