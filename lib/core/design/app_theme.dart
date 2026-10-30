import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 全局主题。
///
/// 排版走 Apple 的路子：大标题紧、正文松、行高偏大，
/// 圆角统一 20/24/28 三档，阴影极浅（靠描边和色阶分层，而不是重投影）。
class WispTheme {
  const WispTheme._();

  /// 字体回退链。系统装了第一个就用第一个——中文最终落到「微软雅黑」/「苹方」。
  ///
  /// 这份列表必须跟着每个 TextStyle 一起走：只要有一处样式**只**设了
  /// fontFamily 却没带 fallback，那处文字就会掉回系统默认字体，
  /// 英文数字的字形和其它地方明显不同（这正是操作提示曾经"字体不一致"的原因）。
  static const List<String> kFontFallback = <String>[
    'SF Pro Text',
    'SF Pro Display',
    'PingFang SC',
    'Microsoft YaHei',
    'Inter',
  ];

  static ThemeData light({String? fontFamily}) => _build(Brightness.light, fontFamily);
  static ThemeData dark({String? fontFamily}) => _build(Brightness.dark, fontFamily);

  static ThemeData _build(Brightness brightness, [String? fontFamily]) {
    final bool isDark = brightness == Brightness.dark;
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: WispColors.teal,
      brightness: brightness,
    ).copyWith(
      primary: isDark ? const Color(0xFF4FD3D2) : WispColors.teal,
      secondary: WispColors.tealLight,
      surface: isDark ? WispColors.darkSurface : WispColors.lightSurface,
      error: WispColors.danger,
    );

    final Color text = isDark ? WispColors.darkText : WispColors.lightText;
    final Color secondary = isDark ? WispColors.darkTextSecondary : WispColors.lightTextSecondary;
    final Color bg = isDark ? WispColors.darkBg : WispColors.lightBg;

    TextStyle t(double size, FontWeight w, {double height = 1.25, double? spacing}) => TextStyle(
          fontSize: size,
          fontWeight: w,
          height: height,
          letterSpacing: spacing,
          color: text,
          fontFamily: fontFamily,
          // 显式带上回退链。SnackBar / Tooltip 这类会**整体替换**
          // DefaultTextStyle 的组件不会从父级继承字体，缺了这行就会掉回系统字体。
          fontFamilyFallback: fontFamily == null ? kFontFallback : null,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamily != null ? null : kFontFallback,
      textTheme: TextTheme(
        displayLarge: t(34, FontWeight.w700, height: 1.15, spacing: -0.8),
        displayMedium: t(28, FontWeight.w700, height: 1.18, spacing: -0.6),
        headlineMedium: t(22, FontWeight.w700, height: 1.2, spacing: -0.3),
        titleLarge: t(18, FontWeight.w600, height: 1.25),
        titleMedium: t(16, FontWeight.w600, height: 1.3),
        bodyLarge: t(15.5, FontWeight.w400, height: 1.45),
        bodyMedium: t(14, FontWeight.w400, height: 1.45),
        bodySmall: t(12.5, FontWeight.w400, height: 1.35),
        labelLarge: t(15, FontWeight.w600, height: 1.2),
      ).apply(
        bodyColor: text,
        displayColor: text,
      ).copyWith(
        bodySmall: t(12.5, FontWeight.w400, height: 1.35).copyWith(color: secondary),
        labelMedium: t(12, FontWeight.w500, height: 1.2).copyWith(color: secondary),
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? WispColors.darkLine : WispColors.lightLine,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: text, size: 22),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: t(18, FontWeight.w600),
        iconTheme: IconThemeData(color: text, size: 22),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? WispColors.darkSurfaceAlt : WispColors.lightText,
        contentTextStyle: t(14, FontWeight.w500).copyWith(
          color: isDark ? WispColors.darkText : Colors.white,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        insetPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      ),
      // 悬停提示（"重新扫描"「手动连接」这类）默认用 bodySmall 的灰色前景，
      // 放在深色气泡上几乎看不清，而且字体也不跟全局走，这里统一掉。
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: isDark ? WispColors.darkSurfaceAlt : WispColors.lightText,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        textStyle: t(12.5, FontWeight.w500, height: 1.3).copyWith(
          color: isDark ? WispColors.darkText : Colors.white,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? WispColors.darkSurface : WispColors.lightSurface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        showDragHandle: true,
        dragHandleColor: isDark ? WispColors.darkLine : WispColors.lightLine,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return isDark ? const Color(0xFF6E7A78) : Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return isDark ? WispColors.darkSurfaceAlt : const Color(0xFFDEDBD2);
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
