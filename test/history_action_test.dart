import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/core/utils/pickers.dart';
import 'package:wisp/models/transfer.dart';

/// 历史记录的"再次发送 / 打开所在目录"依赖两件事：
/// 记录里存了源路径、路径还能对应到真实文件。这组测试盯住这两点。
void main() {
  group('TransferRecord 的路径字段', () {
    test('新字段能落盘也能读回', () {
      final TransferRecord record = TransferRecord(
        id: 'r1',
        peerAlias: '桌面机',
        direction: TransferDirection.outgoing,
        fileNames: <String>['a.txt', 'photos/b.jpg'],
        bytes: 12,
        time: DateTime(2026, 10, 30, 12),
        success: true,
        paths: <String>[r'C:\tmp\a.txt', r'C:\tmp\photos\b.jpg'],
        saveDir: r'C:\Users\x\Downloads\Wisp',
        peerIp: '192.168.0.9',
      );

      final TransferRecord back = TransferRecord.fromJson(record.toJson());

      expect(back.paths, record.paths);
      expect(back.saveDir, record.saveDir);
      expect(back.peerIp, record.peerIp);
      expect(back.fileNames, record.fileNames);
    });

    test('旧版本记录没有这些字段时不会炸，也不会谎报可以重发', () {
      // 1.0.10 之前写进 shared_preferences 的就是这个结构。
      final TransferRecord old = TransferRecord.fromJson(<String, dynamic>{
        'id': 'r0',
        'peer': '旧设备',
        'direction': 'outgoing',
        'files': <String>['a.txt'],
        'bytes': 3,
        'time': '2026-10-01T10:00:00.000',
        'success': true,
      });

      expect(old.paths, isEmpty);
      expect(old.saveDir, isNull);
      expect(old.canResend, isFalse);
    });

    test('源文件被删掉之后 canResend 变为 false', () async {
      final Directory dir = await Directory.systemTemp.createTemp('wisp_hist');
      final File file = File('${dir.path}${Platform.pathSeparator}a.txt');
      await file.writeAsString('x');

      final TransferRecord record = TransferRecord(
        id: 'r2',
        peerAlias: '对面',
        direction: TransferDirection.outgoing,
        fileNames: <String>['a.txt'],
        bytes: 1,
        time: DateTime(2026, 10, 30),
        success: true,
        paths: <String>[file.path],
      );
      expect(record.canResend, isTrue);

      await file.delete();
      expect(record.canResend, isFalse);
      expect(record.existingPaths, isEmpty);

      await dir.delete(recursive: true);
    });

    test('入站记录永远不给重发入口（源文件在对端）', () {
      final TransferRecord record = TransferRecord(
        id: 'r3',
        peerAlias: '对面',
        direction: TransferDirection.incoming,
        fileNames: <String>['a.txt'],
        bytes: 1,
        time: DateTime(2026, 10, 30),
        success: true,
        paths: <String>[r'C:\somewhere\a.txt'],
        saveDir: r'C:\Downloads\Wisp',
      );
      expect(record.canResend, isFalse);
    });
  });

  group('拖拽路径展开', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('wisp_drop');
      await Directory('${root.path}${Platform.pathSeparator}sub').create();
      await File('${root.path}${Platform.pathSeparator}a.txt').writeAsString('aa');
      await File('${root.path}${Platform.pathSeparator}sub${Platform.pathSeparator}b.png')
          .writeAsString('bbb');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('文件夹按"根目录/相对路径"展开，结构与点按钮选文件夹一致', () async {
      final String name = root.path.split(Platform.pathSeparator).last;
      final List<TransferFile> files = await Pickers.fromPaths(<String>[root.path]);

      expect(files.length, 2);
      expect(
        files.map((TransferFile f) => f.name).toSet(),
        <String>{'$name/a.txt', '$name/sub/b.png'},
      );
      // MIME 按扩展名判定，不能因为路径里带目录就错。
      expect(
        files.firstWhere((TransferFile f) => f.name.endsWith('b.png')).mime,
        'image/png',
      );
    });

    test('拖单个文件时名字就是文件名，不带目录前缀', () async {
      final String path = '${root.path}${Platform.pathSeparator}a.txt';
      final List<TransferFile> files = await Pickers.fromPaths(<String>[path]);

      expect(files.length, 1);
      expect(files.single.name, 'a.txt');
      expect(files.single.size, 2);
      expect(files.single.path, path);
    });

    test('路径末尾带分隔符也不会把相对路径切错位', () async {
      final String name = root.path.split(Platform.pathSeparator).last;
      final List<TransferFile> files =
          await Pickers.fromPaths(<String>['${root.path}${Platform.pathSeparator}']);

      expect(files.length, 2);
      expect(
        files.every((TransferFile f) => f.name.startsWith('$name/')),
        isTrue,
      );
    });

    test('不存在的路径直接跳过，不抛异常', () async {
      final List<TransferFile> files =
          await Pickers.fromPaths(<String>['${root.path}${Platform.pathSeparator}nope.txt']);
      expect(files, isEmpty);
    });
  });
}
