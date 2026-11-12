import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 方案 C 迷你 logo 的源码级护栏。
///
/// 本机跑不了 C++ / Swift 编译，两个平台的通知卡图标又是各自现画的
/// （GDI+ 与 NSBezierPath），最容易出现的回归是「改了一边忘了另一边」，
/// 或者有人按旧图标把圆角/线条改回去。这里把两份绘制函数里用到的
/// 归一化坐标（来自 assets/icon/wisp_icon.svg 的 1024 画布）逐项对齐：
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
  /// 顺序按绘制顺序：底板 → 后置描边卡 → 旋转 → 前置消息卡 → 尾 → 线 → 点。
  const List<String> anchors = <String>[
    // squircle 半径 / 渐变
    '0.235',
    // 后置描边文件卡
    '0.410', '0.180', '0.422', '0.445', '0.055',
    // 旋转中心与角度
    '0.617', '0.406', '-9',
    // 前置白色消息卡
    '0.188', '0.500', '0.360', '0.102',
    // 气泡尾
    '0.293', '0.715', '0.176', '0.855', '0.305',
    // 两条文字线
    '0.277', '0.531', '0.320', '0.047', '0.621', '0.100', '0.024',
    // 珊瑚点
    '0.758', '0.117',
  ];

  test('两个平台的迷你 logo 用同一份方案 C 几何', () {
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
          reason: 'Windows 迷你 logo 少了方案 C 的 $anchor');
      expect(mac, contains(anchor),
          reason: 'macOS 迷你 logo 少了方案 C 的 $anchor');
    }

    // 旧构图（单张文件卡 + 两条白线）不能悄悄回来。
    expect(win, isNot(contains('两条白色文字线')));
    expect(mac, isNot(contains('两条白线')));

    // 两边都要写明几何来源，改图标时才知道同步改（注释在函数签名上方）。
    expect(winSource, contains('wisp_icon.svg'));
    expect(macSource, contains('wisp_icon.svg'));
  });

  test('方案 C 矢量源仍是青绿底板 + 珊瑚点 + 两张卡', () {
    if (missing(svg)) return;
    final String source = svg.readAsStringSync();
    expect(source, contains('#0E7C86'), reason: '底板深端变了');
    expect(source, contains('#FF7A59'), reason: '珊瑚点变了');
    expect(source, contains('stroke:#FFFFFF'), reason: '后置描边卡没了');
    expect(source, contains('rx="236"'), reason: 'squircle 圆角变了');
  });
}
