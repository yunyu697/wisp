import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/state/app_state.dart';

/// 原生层把路径交回 Dart 之后的那一半：展开、去重、切页。
///
/// macOS 的 `WispDropView` 与 Windows 的 `WM_DROPFILES` 都只做一件事——把
/// 绝对路径发过来。真正的语义全在这里，所以这条链路以前在 macOS 上虽然
/// "写了"，却从没被跑过（事件从来不发，代码路径不可达）。现在两端都通了，
/// 这一半得有测试兜着：它一旦退化，表现是"拖进来没反应"，同样不报错。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wisp_drop_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  String at(String relative) => '${root.path}${Platform.pathSeparator}$relative';

  test('拖进来的文件夹递归展开，名字保留根目录层级', () async {
    final Directory album = Directory(at('相册'))..createSync();
    File('${album.path}${Platform.pathSeparator}a.jpg').writeAsStringSync('x');
    final Directory nested = Directory('${album.path}${Platform.pathSeparator}子目录')
      ..createSync();
    File('${nested.path}${Platform.pathSeparator}b.txt').writeAsStringSync('yy');

    final AppState state = AppState();
    await state.addDroppedPaths(<String>[album.path]);

    // 两层里的文件都要进来——拖一个文件夹进窗口，用户期望的是"整包可发"。
    expect(state.draft.length, 2);
    expect(
      state.draft.map((f) => f.name).toSet(),
      <String>{'相册/a.jpg', '相册/子目录/b.txt'},
      reason: '名字必须带根目录，接收端才能还原出目录结构',
    );
    // 切页信号：外壳靠它从任意页面翻到发送页。
    expect(state.composeTick, 1);
    expect(state.banner, contains('2 个文件'));
  });

  test('单个文件原样收下，并提示已加入', () async {
    final File file = File(at('报告.pdf'))..writeAsStringSync('hello');

    final AppState state = AppState();
    await state.addDroppedPaths(<String>[file.path]);

    expect(state.draft.length, 1);
    expect(state.draft.single.name, '报告.pdf');
    expect(state.draft.single.size, 5);
    expect(state.composeTick, 1);
    expect(state.banner, contains('1 个文件'));
  });

  test('重复拖同一个文件不会重复入列，也不再切页', () async {
    final File file = File(at('重复.txt'))..writeAsStringSync('x');
    final AppState state = AppState();

    await state.addDroppedPaths(<String>[file.path]);
    final int tickAfterFirst = state.composeTick;
    await state.addDroppedPaths(<String>[file.path]);

    expect(state.draft.length, 1, reason: '同一路径不该出现两条待发项');
    expect(state.composeTick, tickAfterFirst,
        reason: '什么都没加进去就不该把用户从当前页拽走');
    expect(state.banner, contains('已经在待发清单'));
  });

  test('路径全都读不出来时明确告知，而不是静默什么都不做', () async {
    final AppState state = AppState();
    await state.addDroppedPaths(<String>[at('不存在的文件.txt')]);

    expect(state.draft, isEmpty);
    expect(state.composeTick, 0);
    expect(state.banner, isNotNull,
        reason: '拖了东西却没反应是最糟的反馈——必须说清楚为什么没加进来');
  });

  test('空路径列表直接返回，不弹任何提示', () async {
    final AppState state = AppState();
    await state.addDroppedPaths(<String>[]);

    // 拖拽层在 Enter 阶段就把非文件内容挡掉了，正常不会走到这里；
    // 但原生层若发来空数组，不该给用户一条莫名其妙的提示。
    expect(state.banner, isNull);
    expect(state.composeTick, 0);
  });
}
