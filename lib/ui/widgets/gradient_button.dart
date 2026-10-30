import 'package:flutter/material.dart';

import '../../core/design/app_colors.dart';
import '../../core/design/app_motion.dart';

/// 主行动按钮：渐变底 + 按下回弹 + 可切换加载态。
class GradientButton extends StatefulWidget {
  const GradientButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.loading = false,
    this.expand = true,
    this.height = 54,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  final bool expand;
  final double height;

  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && !widget.loading;

  @override
  Widget build(BuildContext context) {
    // 不可点时不用「整块淡化」：青绿渐变压到 45% 透明度在暖白底上会发灰发脏，
    // 白字也跟着糊。改成明确的「浅底 + 次级文字」——一眼看出是禁用态。
    final bool muted = !_enabled && !widget.loading;
    final Color fg = muted ? WispColors.secondaryText(context) : Colors.white;

    final Widget content = AnimatedSwitcher(
      duration: WispMotion.fast,
      child: widget.loading
          ? const SizedBox(
              key: ValueKey<String>('loading'),
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
            )
          : Row(
              key: const ValueKey<String>('label'),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (widget.icon != null) ...<Widget>[
                  Icon(widget.icon, color: fg, size: 19),
                  const SizedBox(width: 8),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
    );

    return GestureDetector(
      onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
      onTapUp: _enabled
          ? (_) {
              setState(() => _pressed = false);
              widget.onPressed!();
            }
          : null,
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1,
        duration: WispMotion.fast,
        curve: Curves.easeOut,
        child: Container(
          height: widget.height,
          width: widget.expand ? double.infinity : null,
          padding: widget.expand ? null : const EdgeInsets.symmetric(horizontal: 26),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: muted ? WispColors.surfaceAlt(context) : null,
            gradient: muted ? null : WispColors.brandGradient,
            borderRadius: BorderRadius.circular(widget.height / 2),
            boxShadow: muted
                ? const <BoxShadow>[]
                : <BoxShadow>[
                    BoxShadow(
                      color: WispColors.teal.withValues(alpha: _pressed ? 0.18 : 0.32),
                      blurRadius: _pressed ? 10 : 22,
                      offset: Offset(0, _pressed ? 3 : 8),
                    ),
                  ],
          ),
          child: content,
        ),
      ),
    );
  }
}

/// 次级按钮：浅底 + 主色文字。
class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.expand = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WispColors.accent(context).withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 46,
          width: expand ? double.infinity : null,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 18, color: WispColors.accent(context)),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: WispColors.accent(context),
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
