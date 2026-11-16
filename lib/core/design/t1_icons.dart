import 'package:flutter/material.dart';

/// t1「青柠绿」双主题图标（设计源：assets/icons/t1/svg）。
///
/// 图标本身是双色的：主描边随明暗主题切换，强调色固定为品牌绿。
/// 因此这里按当前 [Brightness] 选 light/dark 位图，不再用 [Color] 染色——
/// 染色会把强调色一起冲掉，失去这套图标的辨识度。
enum T1Glyph {
  chat,
  devices,
  transfers,
  settings,
  receive,
  send,
}

/// 24×24 线性图标：导航底栏、侧栏与主要动作入口共用。
class WispT1Icon extends StatelessWidget {
  const WispT1Icon(
    this.glyph, {
    super.key,
    this.size = 22,
    this.opacity = 1.0,
    this.forceDark = false,
  });

  final T1Glyph glyph;
  final double size;

  /// 禁用态用降低不透明度表达，不换图。
  final double opacity;

  /// 置于深色渐变底（如主发送圆钮）时强制用浅描边版本。
  final bool forceDark;

  @override
  Widget build(BuildContext context) {
    final bool isDark = forceDark || Theme.of(context).brightness == Brightness.dark;
    final String mode = isDark ? 'dark' : 'light';
    return ExcludeSemantics(
      child: Opacity(
        opacity: opacity,
        child: Image.asset(
          'assets/icons/t1/ui/t1-${glyph.name}-$mode-48.png',
          width: size,
          height: size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}

/// 应用图标：浅色/深色两套主图，用于侧栏顶部等应用内展示位。
class WispT1AppIcon extends StatelessWidget {
  const WispT1AppIcon({super.key, this.size = 34});

  final double size;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return ExcludeSemantics(
      child: Image.asset(
        'assets/icons/t1/app/t1-app-${isDark ? 'dark' : 'light'}-128.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}
