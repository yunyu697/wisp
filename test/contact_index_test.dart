import 'package:flutter_test/flutter_test.dart';

import 'package:wisp/core/utils/contact_index.dart';

/// 联系人按拼音/字母归组：设备名里中英文混排是常态，必须都认得。
void main() {
  group('首字母归组', () {
    test('中文按首字拼音首字母', () {
      expect(contactInitial('张三的 iPhone'), 'Z');
      expect(contactInitial('客厅的 Mac mini'), 'K');
      expect(contactInitial('白板'), 'B');
      expect(contactInitial('王五'), 'W');
    });

    test('英文按首字母且不区分大小写', () {
      expect(contactInitial('ThinkBook-14'), 'T');
      expect(contactInitial('iPhone 15'), 'I');
      expect(contactInitial('android pad'), 'A');
    });

    test('数字、符号、空名归到 #', () {
      expect(contactInitial('192.168.1.5'), '#');
      expect(contactInitial(''), '#');
      expect(contactInitial('   '), '#');
    });
  });

  group('组内排序', () {
    test('中文用全拼而非 Unicode 码点排序', () {
      final List<String> names = <String>['张三', '白板', '客厅'];
      names.sort(compareContactNames);
      expect(names, <String>['白板', '客厅', '张三']);
    });

    test('排序键是小写字母数字串', () {
      expect(contactSortKey('客厅'), startsWith('ke'));
      expect(contactSortKey('ThinkBook-14'), 'thinkbook14');
    });

    test('字母表覆盖 A-Z 与 #，顺序固定', () {
      expect(kContactIndexLetters.length, 27);
      expect(kContactIndexLetters.first, 'A');
      expect(kContactIndexLetters.last, '#');
      expect(kPinnedLetter, '★');
    });
  });
}
