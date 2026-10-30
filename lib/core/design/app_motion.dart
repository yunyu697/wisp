import 'package:flutter/animation.dart';

/// 动效令牌。
///
/// 原则：位移用 easeOutCubic，缩放用带回弹的曲线，颜色用线性；
/// 时长不超过 420ms，避免"炫技式"慢动画拖累操作节奏。
class WispMotion {
  const WispMotion._();

  static const Duration instant = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration base = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 420);

  /// 页面切换：淡入 + 轻微上浮，接近 iOS 的层级感但更轻。
  static const Duration page = Duration(milliseconds: 340);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve emphasis = Curves.easeOutBack;

  /// 列表逐项入场：每项延迟 45ms，最多累计 8 项，避免长列表等待。
  static Duration staggerDelay(int index) =>
      Duration(milliseconds: 45 * (index > 8 ? 8 : index));
}
