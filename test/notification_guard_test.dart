import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 通知闭环的**防回归护栏**。
///
/// 背景：「通知要第二次才会出现」这个问题反复修过好几轮，每轮都是打补丁——
/// 因为通知有**多条出口**，只要有一条绕过统一闭环（发一次就当成功），
/// 原生层没把像素画上去时，那一次请求就会悄无声息地过去，用户必须等下一次
/// 请求才看得到通知。
///
/// 上一轮已经把所有出口收敛到 `AppState._desktopNotice`（先弹、再确认
/// visible+drawn，没画出来就重发）。这个测试的作用是**守住这个收敛**：
/// 以后任何人在 lib/ 里新写一个裸的 `DesktopService.showToast(...)`，
/// 测试立刻失败，问题在合并前就被拦住，而不是等用户第三次反馈。
///
/// 同时守住两条最容易被人"顺手改回去"的关键语义：
///   1. `DesktopWindowState.unknown` 兜底值必须是"不打扰"（visible=false），
///      不能是"当成用户正看着主窗口"——那会把通知直接吞掉。
///   2. 通知必须走 `_desktopNotice`，而不是各处直接发。
void main() {
  final Directory libDir = Directory('${Directory.current.path}/lib');

  List<File> dartFilesUnder(String rel) {
    final Directory dir = Directory('${libDir.path}/$rel');
    if (!dir.existsSync()) return <File>[];
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();
  }

  /// 从 `marker` 所在行往后，找到第一个顶格闭括号，返回该方法体的行区间。
  /// 找不到时返回 null。
  (int, int)? methodBodyRange(List<String> lines, String marker) {
    final int start = lines.indexWhere((String l) => l.contains(marker));
    if (start < 0) return null;
    for (int i = start + 1; i < lines.length; i++) {
      if (lines[i].trimRight() == '  }') return (start, i);
    }
    return null;
  }

  group('通知单一出口护栏', () {
    test('lib/ 下不允许出现绕过 _desktopNotice 的裸通知调用', () {
      // 自测模块允许直调——它要单独验证原生层的每一次绘制。
      final List<File> files = <File>[
        ...dartFilesUnder('.'),
      ].where((File f) => !f.path.contains('${Platform.pathSeparator}selftest${Platform.pathSeparator}')).toList();

      const List<String> banned = <String>[
        'DesktopService.showToast(',
        'DesktopService.updateToast(',
      ];

      final List<String> violations = <String>[];
      for (final File f in files) {
        // app_state.dart 是唯一允许的出口，见下面那条用例。
        if (f.path.endsWith('app_state.dart')) continue;
        final List<String> lines = f.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          for (final String call in banned) {
            if (lines[i].contains(call)) {
              violations.add(
                  '${f.path.replaceAll(libDir.path, 'lib')}:${i + 1}  $call');
            }
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason: '发现绕过统一通知闭环的调用。\n'
            '所有桌面通知必须走 AppState._desktopNotice（它会确认通知真的画出来了，'
            '没画出来会重发）。直接调 DesktopService 的通知方法会退回"发一次就当成功"的'
            '老行为，用户就会遇到"要第二次才会出现"。\n'
            '如需特殊用途，请改用 _desktopNotice 的参数（isUpdate / mode）。\n'
            '违规位置：\n${violations.join('\n')}',
      );
    });

    test('app_state.dart 里的通知调用只在 _desktopNotice 方法体内', () {
      final File f = File('${libDir.path}/state/app_state.dart');
      expect(f.existsSync(), isTrue, reason: '找不到 lib/state/app_state.dart');
      final List<String> lines = f.readAsLinesSync();

      final (int, int)? range =
          methodBodyRange(lines, 'Future<void> _desktopNotice(');
      expect(range, isNotNull,
          reason: 'app_state.dart 里找不到 _desktopNotice —— 通知统一入口被删了？');

      final int start = range!.$1;
      final int end = range.$2;

      const List<String> banned = <String>[
        'DesktopService.showToast(',
        'DesktopService.updateToast(',
      ];

      final List<String> violations = <String>[];
      for (int i = 0; i < lines.length; i++) {
        if (i >= start && i <= end) continue; // 闭环内部，允许。
        for (final String call in banned) {
          if (lines[i].contains(call)) {
            violations.add('app_state.dart:${i + 1}  $call');
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason: '_desktopNotice 之外还有裸通知调用。\n'
            '这些出口绕过了"确认画出来了再算成功"的闭环，会让通知在原生层'
            '没画出来时被静默吞掉（表现为"要第二次才会出现"）。\n'
            '违规位置：\n${violations.join('\n')}',
      );
    });

    test('_desktopNotice 必须带重试与绘制确认', () {
      final File f = File('${libDir.path}/state/app_state.dart');
      final List<String> lines = f.readAsLinesSync();
      final (int, int)? range =
          methodBodyRange(lines, 'Future<void> _desktopNotice(');
      expect(range, isNotNull);
      final String body = lines.sublist(range!.$1, range.$2 + 1).join('\n');

      expect(body, contains('_surfaceReady('),
          reason: '_desktopNotice 没有调用 _surfaceReady —— 不确认原生层真的画出来了。');
      expect(
        body,
        anyOf(contains('attempt'), contains('for (')),
        reason: '_desktopNotice 没有重试逻辑 —— 原生层第一次没画出来时，'
            '用户就得等下一次请求才看得到通知。',
      );
    });

    test('通知出口都走 _desktopNotice', () {
      final File f = File('${libDir.path}/state/app_state.dart');
      final String source = f.readAsStringSync();

      // 这几个是所有会打扰桌面的出口，每一个都必须经过闭环。
      for (final String fn in <String>[
        '_notifyDesktopIncoming',
        '_updateDesktopProgress',
        '_notifyDesktopFinished',
      ]) {
        expect(
          source.contains('Future<void> $fn(') || source.contains('void $fn('),
          isTrue,
          reason: '找不到通知出口 $fn',
        );
      }

      // _desktopNotice 的调用点数量：三个出口 + 进度首次 + 结局，
      // 至少要有若干处真的调它。
      final int noticeCalls =
          RegExp(r'_desktopNotice\(').allMatches(source).length;
      expect(noticeCalls, greaterThanOrEqualTo(4),
          reason: '_desktopNotice 的调用点只有 $noticeCalls 处，'
              '说明某个通知出口可能没走统一闭环。');
    });
  });

  group('关键语义护栏', () {
    test('unknown 兜底值必须是"不打扰"，不能当成用户在看着主窗口', () {
      final File f = File('${libDir.path}/services/desktop_service.dart');
      final List<String> lines = f.readAsLinesSync();
      final int start =
          lines.indexWhere((String l) => l.contains('static const DesktopWindowState unknown'));
      expect(start, isNotNull,
          reason: '找不到 DesktopWindowState.unknown 兜底值定义');
      int end = -1;
      for (int i = start + 1; i < lines.length; i++) {
        if (lines[i].trim() == ');') {
          end = i;
          break;
        }
      }
      expect(end, isNot(-1));
      final String block = lines.sublist(start, end + 1).join('\n');

      expect(block, contains('visible: false'),
          reason: 'unknown.visible 必须为 false。'
              '若为 true，拿不到原生状态时会被当成"用户正看着主窗口"，'
              '通知被直接吞掉——这就是"要第二次才会出现"。');
      expect(block, contains('active: false'),
          reason: 'unknown.active 必须为 false（理由同 visible）。');
      expect(block, isNot(contains('visible: true')));
      expect(block, isNot(contains('active: true')));
    });

    test('userIsLooking 必须同时要求 visible 与 active', () {
      final File f = File('${libDir.path}/services/desktop_service.dart');
      final String source = f.readAsStringSync();
      expect(source, contains('bool get userIsLooking => visible && active'),
          reason: 'userIsLooking 的判定被改过了，请确认语义是否还正确。');
    });

    test('isWindowVisible 拿不到状态时不能返回 true', () {
      final File f = File('${libDir.path}/services/desktop_service.dart');
      final List<String> lines = f.readAsLinesSync();
      final (int, int)? range =
          methodBodyRange(lines, 'static Future<bool> isWindowVisible()');
      expect(range, isNotNull,
          reason: '找不到 isWindowVisible —— 它的异常分支语义必须显式声明。');
      final String body = lines.sublist(range!.$1, range.$2 + 1).join('\n');

      expect(
        body,
        isNot(contains('return true')),
        reason: 'isWindowVisible 在异常分支里返回了 true。\n'
            'true 表示"用户正看着主窗口"，会让桌面通知被判定为多余而直接吞掉——'
            '用户看到的就是"通知要下一次才出现"。拿不到状态时必须返回 false。',
      );
    });
  });
}
