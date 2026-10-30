import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/design/app_colors.dart';

/// 扫描雷达：三圈错相位扩散的光环。
///
/// 只用一个 AnimationController 驱动三圈（相位差 1/3），
/// 比开三个控制器省资源，节奏也更均匀。
class RadarView extends StatefulWidget {
  const RadarView({super.key, this.size = 220, this.label = '正在寻找附近的设备'});

  final double size;
  final String label;

  @override
  State<RadarView> createState() => _RadarViewState();
}

class _RadarViewState extends State<RadarView> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: widget.size,
          height: widget.size,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (BuildContext context, Widget? child) => CustomPaint(
              painter: _RadarPainter(progress: _controller.value),
              child: child,
            ),
            child: Center(
              child: Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: WispColors.brandGradient,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: WispColors.teal.withValues(alpha: 0.35),
                      blurRadius: 26,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(Icons.wifi_tethering_rounded, color: Colors.white, size: 32),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          widget.label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: WispColors.secondaryText(context),
              ),
        ),
      ],
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double maxRadius = size.width / 2;

    for (int i = 0; i < 3; i++) {
      final double phase = (progress + i / 3) % 1.0;
      final double radius = 40 + (maxRadius - 40) * Curves.easeOut.transform(phase);
      final double fade = math.min(1.0, phase * 6);
      final double opacity = ((1 - phase) * 0.34 * fade).clamp(0.0, 1.0).toDouble();
      final Paint paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = WispColors.teal.withValues(alpha: opacity);
      canvas.drawCircle(center, radius, paint);
    }

    // 中心一圈淡淡的实底，让图标有"落在盘面上"的稳定感
    final Paint disc = Paint()..color = WispColors.teal.withValues(alpha: 0.06);
    canvas.drawCircle(center, 52, disc);
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) => oldDelegate.progress != progress;
}
