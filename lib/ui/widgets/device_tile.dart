import 'package:flutter/material.dart';

import '../../core/design/app_colors.dart';
import '../../core/design/app_motion.dart';
import '../../models/device.dart';

/// 设备图标：按设备类型给不同底色，圆角方形，接近 iOS 的 app 图标观感。
class DeviceAvatar extends StatelessWidget {
  const DeviceAvatar({super.key, required this.kind, this.size = 46});

  final DeviceKind kind;
  final double size;

  IconData get _icon {
    switch (kind) {
      case DeviceKind.mobile:
        return Icons.smartphone_rounded;
      case DeviceKind.desktop:
        return Icons.laptop_mac_rounded;
      case DeviceKind.web:
        return Icons.language_rounded;
      case DeviceKind.headless:
        return Icons.terminal_rounded;
      case DeviceKind.server:
        return Icons.dns_rounded;
      case DeviceKind.unknown:
        return Icons.devices_other_rounded;
    }
  }

  /// 设备类型色。整体收在「青绿 → 浅青」这条主线上，服务器与移动端用珊瑚区分，
  /// 保证列表里一眼能分出类型，又不跳出品牌色。
  List<Color> get _colors {
    switch (kind) {
      case DeviceKind.mobile:
        return <Color>[WispColors.teal, WispColors.tealLight];
      case DeviceKind.desktop:
        return <Color>[const Color(0xFF2C7C9E), const Color(0xFF57B6D4)];
      case DeviceKind.web:
        return <Color>[WispColors.mint, const Color(0xFF63D9B6)];
      case DeviceKind.headless:
        return <Color>[const Color(0xFF8E8E93), const Color(0xFFB0B0B8)];
      case DeviceKind.server:
        return <Color>[WispColors.coral, const Color(0xFFFF9E80)];
      case DeviceKind.unknown:
        return <Color>[const Color(0xFF6E7A78), const Color(0xFF9AA7A4)];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.30),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _colors,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: _colors.first.withValues(alpha: 0.28),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Icon(_icon, color: Colors.white, size: size * 0.48),
    );
  }
}

/// 设备行：点击进入详情/发送，长按收藏。
class DeviceTile extends StatelessWidget {
  const DeviceTile({
    super.key,
    required this.device,
    required this.onTap,
    this.onLongPress,
    this.trailing,
  });

  final WispDevice device;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WispColors.surface(context),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(20),
        splashColor: WispColors.teal.withValues(alpha: 0.06),
        highlightColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: WispColors.line(context)),
          ),
          child: Row(
            children: <Widget>[
              Hero(
                tag: 'device-${device.key}',
                child: DeviceAvatar(kind: device.kind),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      device.alias,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${device.modelLabel} · ${device.ip}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing ??
                  AnimatedOpacity(
                    opacity: 1,
                    duration: WispMotion.fast,
                    child: Icon(
                      Icons.chevron_right_rounded,
                      color: WispColors.secondaryText(context),
                      size: 20,
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
