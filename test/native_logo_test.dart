import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// t1 迷你 logo 的源码级护栏。
///
/// 本机跑不了 C++ / Swift 编译，两个平台的通知卡图标又是各自现画的
/// （GDI+ 与 NSBezierPath），最容易出现的回归是「改了一边忘了另一边」，
/// 或者有人按旧图标把圆角/线条改回去。这里把两份绘制函数里用到的
/// 归一化坐标（来自 assets/icons/t1/svg/t1-app-light.svg）逐项对齐：
/// 少一个、改一个，测试立刻失败。
///
/// 注意：macOS 菜单栏是 20pt 单色模板图（系统自动着色），刻意不套彩色
/// 构图，不在这个护栏的约束范围内。
void main() {
  final File cpp = File('windows/runner/flutter_window.cpp');
  final File swift = File('macos/Runner/WispOverlay.swift');
  final File svg = File('assets/icon/wisp_icon.svg');

  bool missing(File file) {
    if (!file.existsSync()) {
      markTestSkipped('找不到 ${file.path}');
      return true;
    }
    return false;
  }

  /// 只截绘制函数本体，避免别处的同值常量把断言糊过去。
  String section(String source, String start, String end) {
    final int a = source.indexOf(start);
    if (a < 0) return '';
    final int b = source.indexOf(end, a + start.length);
    return b < 0 ? source.substring(a) : source.substring(a, b);
  }

  /// 两平台必须逐字出现的关键几何常量。
  /// 顺序按绘制顺序：底板 → 后置浅绿文件卡 → 三个绿点 →
  /// 前置白色消息卡 → 气泡尾 → 卡内文件+上传箭头。
  const List<String> anchors = <String>[
    // squircle 半径
    '0.236',
    // 后置浅绿文件卡
    '0.491', '0.405', '0.455', '0.318', '0.100',
    // 三个绿点
    '0.609', '0.718', '0.827', '0.541', '0.046',
    // 前置白色消息卡
    '0.136', '0.200', '0.573', '0.382', '0.114',
    // 气泡尾
    '0.250', '0.582', '0.236', '0.668', '0.346', '0.586',
    // 卡内文件 + 上传箭头（描边宽度）
    '0.355', '0.295', '0.445', '0.345', '0.495', '0.473', '0.020',
  ];

  test('两个平台的迷你 logo 用同一份 t1 几何', () {
    if (missing(cpp) || missing(swift) || missing(svg)) return;

    final String winSource = cpp.readAsStringSync();
    final String macSource = swift.readAsStringSync();
    final String win = section(winSource, 'void DrawMiniIcon(',
        '// 渐变圆角按钮');
    final String mac = section(macSource,
        'private func drawIcon(in rect: NSRect)', 'private func drawButton(');

    expect(win, isNotEmpty, reason: 'Windows 侧找不到 DrawMiniIcon 函数体');
    expect(mac, isNotEmpty, reason: 'macOS 侧找不到 drawIcon(in:) 函数体');

    for (final String anchor in anchors) {
      expect(win, contains(anchor),
          reason: 'Windows 迷你 logo 少了 t1 的 $anchor');
      expect(mac, contains(anchor),
          reason: 'macOS 迷你 logo 少了 t1 的 $anchor');
    }

    // 旧构图（方案 C 青绿卡 + 珊瑚点）不能悄悄回来。
    expect(win, isNot(contains('珊瑚圆点')));
    expect(mac, isNot(contains('珊瑚圆点')));

    // 两边都要写明几何来源，改图标时才知道同步改（注释在函数签名上方）。
    expect(winSource, contains('t1-app-light.svg'));
    expect(macSource, contains('t1-app-light.svg'));
  });

  test('t1 矢量源仍是绿色 squircle + 双气泡 + 三个绿点', () {
    if (missing(svg)) return;
    final String source = svg.readAsStringSync();
    expect(source, contains('#4ED77A'), reason: '底板亮端变了');
    expect(source, contains('#0FA85C'), reason: '底板深端变了');
    expect(source, contains('#E8F8EE'), reason: '后置浅绿气泡卡没了');
    expect(source, contains('rx="104"'), reason: 'squircle 圆角变了');
  });
}
