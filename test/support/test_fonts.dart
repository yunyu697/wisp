import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 加载测试用的中文字体与 Material 图标字体，返回可用的字体家族名。
///
/// flutter_test 默认只给一个叫 Ahem 的占位字体，
/// 中文和图标都会渲染成方块，所以这里显式把系统字体灌进去。
/// 找不到中文字体时退回 Roboto，图标则退回 Flutter 自带的那份。
Future<String> loadTestFonts() async {
  // 图标字体：直接用 SDK 里自带的那份，保证图标不是方块。
  for (final String path in <String>[
    r'C:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    r'C:\Users\Tyler Zhang\.workbuddy-ai\binaries\flutter\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
  ]) {
    final File file = File(path);
    if (!await file.exists()) continue;
    final Uint8List bytes = await file.readAsBytes();
    final FontLoader loader = FontLoader('MaterialIcons')
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    break;
  }

  // 中文字体：优先等线/黑体（TTC 合集 flutter 读不了，跳过）。
  for (final String path in <String>[
    r'C:\Windows\Fonts\Deng.ttf',
    r'C:\Windows\Fonts\simhei.ttf',
    '/System/Library/Fonts/PingFang.ttc',
  ]) {
    final File file = File(path);
    if (!await file.exists()) continue;
    try {
      final Uint8List bytes = await file.readAsBytes();
      final FontLoader loader = FontLoader('WispTestFont')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();
      return 'WispTestFont';
    } catch (_) {
      continue;
    }
  }
  return 'Roboto';
}
