import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/core/file_names.dart';

/// 接收端落盘文件名的净化规则。
///
/// 背景：`fileName` 由对端完全控制。原实现直接把它拼进落盘路径，
/// 发一个 `..\..\Startup\x.bat` 就能写到目标目录外面（自动接收时无感）。
/// 这组用例把「只能是一个纯文件名」这条边界钉死。
void main() {
  group('safeFileName：路径穿越', () {
    test('剥掉 Unix 相对路径', () {
      expect(safeFileName('../../../etc/passwd'), 'passwd');
      expect(safeFileName('/tmp/abs.txt'), 'abs.txt');
      expect(safeFileName('a/b/c/d.txt'), 'd.txt');
    });

    test('剥掉 Windows 相对路径', () {
      expect(safeFileName(r'..\..\Startup\x.bat'), 'x.bat');
      expect(safeFileName(r'C:\Windows\System32\evil.dll'), 'evil.dll');
    });

    test('两种分隔符混写只取最后一段', () {
      expect(safeFileName(r'a/b\c/d.txt'), 'd.txt');
      expect(safeFileName(r'..\../..\x.sh'), 'x.sh');
    });

    test('`.` / `..` / 空名退回占位名', () {
      expect(safeFileName('..'), '未命名文件');
      expect(safeFileName('.'), '未命名文件');
      expect(safeFileName(''), '未命名文件');
      expect(safeFileName('   '), '未命名文件');
      expect(safeFileName('../'), '未命名文件');
      expect(safeFileName(r'..\..'), '未命名文件');
    });

    test('任何输入都不含路径分隔符', () {
      const List<String> nasty = <String>[
        r'..\..\..\x',
        '../../x',
        r'C:\x\y',
        '//server/share/x.txt',
        r'\\?\C:\x.txt',
        r'..\x/../../y',
      ];
      for (final String raw in nasty) {
        final String safe = safeFileName(raw);
        expect(safe.contains('/'), isFalse, reason: '输入 $raw 产出 $safe');
        expect(safe.contains(r'\'), isFalse, reason: '输入 $raw 产出 $safe');
        expect(safe.contains('..'), isFalse, reason: '输入 $raw 产出 $safe');
      }
    });
  });

  group('safeFileName：Windows 特殊名', () {
    test('保留设备名加前缀', () {
      expect(safeFileName('CON'), '_CON');
      expect(safeFileName('con.txt'), '_con.txt');
      expect(safeFileName('COM1'), '_COM1');
      expect(safeFileName('lpt9.log'), '_lpt9.log');
      // 只是包含关键字的普通名字不受影响。
      expect(safeFileName('console.log'), 'console.log');
      expect(safeFileName('aux-notes.md'), 'aux-notes.md');
    });

    test('非法字符换成下划线', () {
      expect(safeFileName('a:b.txt'), 'a_b.txt');
      expect(safeFileName('a<b>c"d|e?f*g.txt'), 'a_b_c_d_e_f_g.txt');
    });

    test('去掉结尾的点与空格', () {
      expect(safeFileName('trail.  '), 'trail');
      expect(safeFileName('  lead.txt'), 'lead.txt');
      expect(safeFileName('....'), '未命名文件');
    });

    test('去掉控制字符', () {
      expect(safeFileName('na\u0000me.txt'), 'name.txt');
      expect(safeFileName('a\nb\tc.txt'), 'abc.txt');
    });
  });

  group('safeFileName：正常名字原样保留', () {
    test('中文 / 空格 / emoji 不动', () {
      expect(safeFileName('大文件 副本.tar.gz'), '大文件 副本.tar.gz');
      expect(safeFileName('🎉 party.png'), '🎉 party.png');
      expect(safeFileName('a.b.c.txt'), 'a.b.c.txt');
    });

    test('超长名字按 rune 截断且保留扩展名', () {
      final String long = '${'a' * 300}.txt';
      final String safe = safeFileName(long);
      expect(safe.length, lessThanOrEqualTo(120));
      expect(safe.endsWith('.txt'), isTrue);
    });

    test('超长 emoji 名字不会劈成半个字符', () {
      final String long = '${'🎉' * 300}.png';
      final String safe = safeFileName(long);
      expect(safe.runes.length, lessThanOrEqualTo(120));
      expect(safe.endsWith('.png'), isTrue);
      // 每个 rune 都应是完整的 emoji（U+1F389），不能出现代理项。
      for (final int rune in safe.replaceAll('.png', '').runes) {
        expect(rune, 0x1F389);
      }
    });
  });
}
