/// 把对端报来的文件名收成一个「只能落在当前目录里」的安全名字。
///
/// 这是接收端的**安全边界**：协议里的 `fileName` 完全由对端控制，
/// 直接拼进落盘路径就等于把写入位置交给对方。`../../StartUp/x.bat`
/// 这种名字在自动接收开启时会被静默写进启动目录。
///
/// 只做「取最后一段 + 过滤非法字符」，不做编码转换——中文、空格、
/// emoji 都原样保留，用户看到的还是对方发来的那个名字。
library;

/// 文件名主干上限（不含扩展名以外的部分）。Windows 整路径上限 260，
/// 留出目录深度与「 (12)」去重后缀的余量。
const int _maxLength = 120;

/// Windows 保留设备名。即使带扩展名（`CON.txt`）也仍然中招，必须前缀化。
final Set<String> _reservedNames = <String>{
  'con',
  'prn',
  'aux',
  'nul',
  for (int i = 1; i <= 9; i++) 'com$i',
  for (int i = 1; i <= 9; i++) 'lpt$i',
};

/// Windows 上不允许出现在文件名里的字符（Unix 上虽合法，但跨平台收包要统一）。
const String _illegalChars = '<>:"|?*';

/// 净化 [raw]，返回可以安全拼进会话目录的文件名。
///
/// 保证：不含路径分隔符、不含控制字符、不是 `.` / `..`、不以点或空格结尾、
/// 不是保留设备名、长度有上限。无法救回时返回 [fallback]。
String safeFileName(String raw, {String fallback = '未命名文件'}) {
  String name = raw;

  // 1) 只取最后一段。同时认 `/` 与 `\`——Windows 上两种写法都能穿越。
  final int slash = name.lastIndexOf('/');
  final int backslash = name.lastIndexOf('\\');
  final int cut = slash > backslash ? slash : backslash;
  if (cut >= 0) name = name.substring(cut + 1);

  // 2) 去掉控制字符（含 NUL），Windows 非法字符换成下划线。
  final StringBuffer buffer = StringBuffer();
  for (final int rune in name.runes) {
    if (rune < 0x20 || rune == 0x7f) continue;
    if (_illegalChars.codeUnits.contains(rune)) {
      buffer.write('_');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  name = buffer.toString();

  // 3) Windows 不允许结尾是点或空格（`x.txt.` 会被系统截断成 `x.txt`），
  //    首尾空格也一并清掉，否则名字看起来一样、实际不同。
  name = name.replaceAll(RegExp(r'[. ]+$'), '').trim();

  // 4) 空名 / `.` / `..` 一律退回占位名。
  if (name.isEmpty || name == '.' || name == '..') return fallback;

  // 5) 保留设备名：`CON`、`con.txt`、`COM1` 都会被系统当成设备，前缀化避开。
  //    比对用小写——集合里存的就是小写，`CON` 与 `con` 同样中招。
  final String stem = name.split('.').first.toLowerCase();
  if (_reservedNames.contains(stem)) name = '_$name';

  // 6) 长度上限：保留扩展名，截断主干（按 rune 截，别把 emoji 劈成半个）。
  final List<int> runes = name.runes.toList();
  if (runes.length > _maxLength) {
    final int dot = name.lastIndexOf('.');
    final bool hasExt = dot > 0 && name.length - dot <= 16;
    final String ext = hasExt ? name.substring(dot) : '';
    final List<int> stemRunes =
        (hasExt ? name.substring(0, dot) : name).runes.toList();
    final int keep = _maxLength - ext.runes.length;
    name = '${String.fromCharCodes(stemRunes.take(keep))}$ext';
  }

  return name;
}
