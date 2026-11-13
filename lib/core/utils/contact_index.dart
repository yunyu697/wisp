/// 联系人按拼音/字母归组用的索引键。
///
/// 中文设备名（"客厅的 Mac mini"、"张三的 iPhone"）按首字拼音的首字母归到
/// A–Z；英文/数字开头直接用首字母；其余归到 `#`。纯 Dart 实现，无平台通道。
library;

import 'package:lpinyin/lpinyin.dart';

/// 右侧字母导航条的顺序。`★` 是置顶组，单独放最前面。
const String kPinnedLetter = '★';

const List<String> kContactIndexLetters = <String>[
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '#',
];

bool _isCjk(int rune) => rune >= 0x3400 && rune <= 0x9FFF;

bool _isAsciiLetter(int code) =>
    (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);

/// 名称归到哪个字母组。
String contactInitial(String name) {
  final String trimmed = name.trim();
  if (trimmed.isEmpty) return '#';
  final int rune = trimmed.runes.first;
  if (_isAsciiLetter(rune)) {
    return String.fromCharCode(rune >= 0x61 ? rune - 32 : rune);
  }
  if (_isCjk(rune)) {
    try {
      final String pinyin =
          PinyinHelper.getFirstWordPinyin(String.fromCharCode(rune));
      if (pinyin.isNotEmpty) {
        final int first = pinyin.codeUnitAt(0);
        if (_isAsciiLetter(first)) {
          return String.fromCharCode(first >= 0x61 ? first - 32 : first);
        }
      }
    } catch (_) {
      // 字典没覆盖的生僻字归到 #，别让整个列表崩掉。
    }
  }
  return '#';
}

/// 同组内的排序键：中文用全拼，其余用小写原名，忽略标点与空格。
String contactSortKey(String name) {
  final String trimmed = name.trim();
  if (trimmed.isEmpty) return '\uffff';
  final int rune = trimmed.runes.first;
  if (_isCjk(rune)) {
    try {
      final String pinyin = PinyinHelper.getPinyinE(
        trimmed,
        separator: '',
        defPinyin: '',
        format: PinyinFormat.WITHOUT_TONE,
      ).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (pinyin.isNotEmpty) return pinyin;
    } catch (_) {
      // 退回原名排序。
    }
  }
  return trimmed.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// 同字母组内按全拼/原名排序；完全相同时按原名稳定收尾。
int compareContactNames(String a, String b) {
  final int primary = contactSortKey(a).compareTo(contactSortKey(b));
  if (primary != 0) return primary;
  return a.toLowerCase().compareTo(b.toLowerCase());
}
