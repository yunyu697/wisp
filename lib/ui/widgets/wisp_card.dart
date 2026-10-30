import 'package:flutter/material.dart';

import '../../core/design/app_colors.dart';
import '../../core/design/app_motion.dart';

/// 通用卡片：靠 1px 描边 + 极浅阴影分层，而不是重投影。
class WispCard extends StatelessWidget {
  const WispCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 24,
    this.onTap,
    this.color,
    this.border = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final Color? color;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final BorderRadius r = BorderRadius.circular(radius);
    return Material(
      color: color ?? WispColors.surface(context),
      borderRadius: r,
      child: InkWell(
        onTap: onTap,
        borderRadius: r,
        splashColor: WispColors.teal.withValues(alpha: 0.06),
        highlightColor: Colors.transparent,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: r,
            border: border ? Border.all(color: WispColors.line(context)) : null,
            boxShadow: isDark
                ? null
                : <BoxShadow>[
                    BoxShadow(
                      color: const Color(0xFF10201F).withValues(alpha: 0.04),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 列表逐项入场：淡入 + 上浮 + 轻微放大。
class StaggeredItem extends StatefulWidget {
  const StaggeredItem({
    super.key,
    required this.index,
    required this.child,
    this.duration = WispMotion.base,
  });

  final int index;
  final Widget child;
  final Duration duration;

  @override
  State<StaggeredItem> createState() => _StaggeredItemState();
}

class _StaggeredItemState extends State<StaggeredItem> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: WispMotion.enter,
  );

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(WispMotion.staggerDelay(widget.index), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      builder: (BuildContext context, Widget? child) {
        final double t = _curve.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 14),
            child: Transform.scale(scale: 0.97 + 0.03 * t, child: child),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// 按下轻微回弹的主按钮。
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.97,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => setState(() => _pressed = true),
      onTapCancel: widget.onTap == null ? null : () => setState(() => _pressed = false),
      onTapUp: widget.onTap == null
          ? null
          : (_) {
              setState(() => _pressed = false);
              widget.onTap!();
            },
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1,
        duration: WispMotion.fast,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
