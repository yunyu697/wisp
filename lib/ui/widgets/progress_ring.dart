import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/design/app_colors.dart';

/// 环形进度：圆头端点 + 补间动画，数字随进度一起走。
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.progress,
    this.size = 208,
    this.strokeWidth = 12,
    this.child,
    this.showGradient = true,
  });

  final double progress;
  final double size;
  final double strokeWidth;
  final Widget? child;
  final bool showGradient;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: progress.clamp(0.0, 1.0).toDouble()),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double value, Widget? _) {
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _RingPainter(
              progress: value,
              strokeWidth: strokeWidth,
              track: isDark ? WispColors.darkSurfaceAlt : WispColors.lightSurfaceAlt,
              gradient: showGradient,
            ),
            child: Center(child: child),
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.strokeWidth,
    required this.track,
    required this.gradient,
  });

  final double progress;
  final double strokeWidth;
  final Color track;
  final bool gradient;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = (size.width - strokeWidth) / 2;
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    final Paint trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawCircle(center, radius, trackPaint);

    if (progress <= 0) return;

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    if (gradient) {
      paint.shader = const SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: math.pi * 1.5,
        colors: <Color>[WispColors.teal, WispColors.tealLight, WispColors.mint, WispColors.teal],
        stops: <double>[0, 0.35, 0.7, 1],
      ).createShader(rect);
    } else {
      paint.color = WispColors.teal;
    }

    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.track != track;
}

/// 细长进度条（文件行内用）。
class SlimProgress extends StatelessWidget {
  const SlimProgress({super.key, required this.value, this.height = 4});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: value.clamp(0.0, 1.0).toDouble()),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
        builder: (BuildContext context, double v, Widget? _) => LinearProgressIndicator(
          value: v,
          minHeight: height,
          backgroundColor: WispColors.surfaceAlt(context),
          valueColor: const AlwaysStoppedAnimation<Color>(WispColors.teal),
        ),
      ),
    );
  }
}
