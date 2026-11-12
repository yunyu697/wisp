import 'package:flutter/material.dart';

/// Wisp 色板。
///
/// 主色取应用图标本身的「青绿 → 浅青」：方案 C 的 squircle 底板就是这道
/// 135° 渐变，白色消息卡叠在上面；第三色珊瑚只用在极小面积的点缀上
/// （图标右上角那颗正在移动的数据点）。中性色偏暖，与界面底色同源，
/// 保证深色/浅色主题下图标与界面都是同一套色。
///
/// 原生层（`windows/runner/flutter_window.cpp` 的 `kBrand` / `kAccent`）
/// 与这里是同一套值，改色必须两边一起改，否则通知卡和界面会不同色。
/// 所有颜色都成对提供 light / dark，界面里不要写死色值。
class WispColors {
  const WispColors._();

  // ---- 品牌 ----
  static const Color teal = Color(0xFF0E7C86); // 图标底板深端
  static const Color tealLight = Color(0xFF3AC8CB); // 图标底板浅端
  static const Color mint = Color(0xFF2FBF9A); // 第三色（进度环收尾）
  static const Color coral = Color(0xFFFF7A59); // 图标右上角那颗点，用量极小

  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[teal, Color(0xFF23A2A9)],
  );

  static const LinearGradient softGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFF1B8F98), Color(0xFF45C4C6)],
  );

  // ---- 语义 ----
  static const Color success = Color(0xFF34C759);
  static const Color warning = Color(0xFFFF9F0A);
  static const Color danger = Color(0xFFFF3B30);

  // ---- 浅色（暖中性，与图标底色同源）----
  static const Color lightBg = Color(0xFFF7F6F2);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceAlt = Color(0xFFEDEBE4);
  static const Color lightText = Color(0xFF17191A);
  static const Color lightTextSecondary = Color(0xFF6B7170);
  static const Color lightLine = Color(0xFFE5E2DA);

  // ---- 深色（带一点青的墨色，而不是纯黑）----
  static const Color darkBg = Color(0xFF0A0F10);
  static const Color darkSurface = Color(0xFF111A1B);
  static const Color darkSurfaceAlt = Color(0xFF192526);
  static const Color darkText = Color(0xFFF0F5F5);
  static const Color darkTextSecondary = Color(0xFF93A5A6);
  static const Color darkLine = Color(0xFF233032);

  static Color accent(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? const Color(0xFF4FD3D2) : teal;

  static Color secondaryText(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkTextSecondary : lightTextSecondary;

  static Color surface(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkSurface : lightSurface;

  static Color surfaceAlt(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkSurfaceAlt : lightSurfaceAlt;

  static Color line(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkLine : lightLine;
}
