import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Windows 原生层的源码级编译护栏。
///
/// 本机没有可用的 MSVC 工具链，C++ 只能靠 CI 编译；而 const 一致性这类错误
/// 在 Dart 侧完全看不出来。v2.0.0 首轮 CI 就是这么挂的：悬浮球退役时把
/// `BallWorkArea() const` 改名成 `ToastWorkArea() const`，定位依据却从成员
/// HWND 换成了 `Win32Window::GetHandle()`（非 const 方法），MSVC 直接 C2662。
/// 这里把这类错误挡在推 tag 之前。
void main() {
  final File cpp = File('windows/runner/flutter_window.cpp');
  final File header = File('windows/runner/flutter_window.h');

  late String cppText;
  late String headerText;

  setUpAll(() {
    cppText = cpp.readAsStringSync();
    headerText = header.readAsStringSync();
  });

  String bodyOf(String source, int openBrace) {
    int depth = 1;
    int i = openBrace + 1;
    while (i < source.length && depth > 0) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') depth--;
      i++;
    }
    return source.substring(openBrace + 1, i - 1);
  }

  test('通知卡落点函数不能是 const（要调非 const 的 GetHandle）', () {
    expect(cppText, contains('FlutterWindow::ToastWorkArea()'),
        reason: '通知卡定位函数应仍在 Windows 原生层');
    expect(cppText, isNot(contains('FlutterWindow::ToastWorkArea() const')),
        reason: 'const 成员函数里调不到 Win32Window::GetHandle()，CI 会报 C2662');
    expect(headerText, contains('RECT ToastWorkArea();'),
        reason: '头文件声明必须和 cpp 定义同步去掉 const');
    expect(headerText, isNot(contains('ToastWorkArea() const')),
        reason: '头文件里残留 const 声明同样会编译失败');
  });

  test('任何 const 成员函数体内都不调用 GetHandle()', () {
    // 找所有形如 `... ) const {` 的定义，逐个检查函数体。
    // 当前 cpp 里已无 const 成员函数，扫到 0 个是正常的；
    // 这条护栏针对的是「以后又有人给通知卡定位函数加回 const」。
    final RegExp constFn = RegExp(r'\)\s*const\s*\{');
    for (final Match match in constFn.allMatches(cppText)) {
      final int open = cppText.indexOf('{', match.start);
      final String body = bodyOf(cppText, open);
      expect(body.contains('GetHandle()'), isFalse,
          reason: 'const 成员函数调用了非 const 的 GetHandle()：'
              '${cppText.substring(match.start, (match.start + 80).clamp(0, cppText.length))}');
    }
  });

  test('cpp 里的 FlutterWindow 方法在头文件中都有声明', () {
    final RegExp def = RegExp(r'FlutterWindow::(\w+)\s*\(');
    final Set<String> names = <String>{};
    for (final Match match in def.allMatches(cppText)) {
      names.add(match.group(1)!);
    }
    expect(names.length, greaterThan(10), reason: '解析不到足够的原生方法');
    for (final String name in names) {
      expect(headerText.contains('$name('), isTrue,
          reason: 'cpp 里有 FlutterWindow::$name 的定义，头文件却找不到声明');
    }
  });
}
