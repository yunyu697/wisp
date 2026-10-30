import 'package:flutter/material.dart';

import '../../core/design/app_colors.dart';

import '../../state/app_state.dart';

/// 本机身份卡：设备名、局域网地址、指纹、可见性开关。
///
/// 这是"我是谁"的第一块信息，放在页面最上方，
/// 让用户随时确认自己在网络里的身份，而不是把它藏进设置。
class IdentityCard extends StatelessWidget {
  const IdentityCard({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final bool visible = state.settings.visible;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            WispColors.teal.withValues(alpha: 0.10),
            WispColors.tealLight.withValues(alpha: 0.07),
          ],
        ),
        border: Border.all(color: WispColors.teal.withValues(alpha: 0.14)),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              _StatusDot(active: visible),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      state.settings.alias,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      visible
                          ? '局域网内可见 · ${state.localIp ?? "未连接网络"}'
                          : '已隐身 · 别人看不到这台设备',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Transform.scale(
                scale: 0.86,
                child: Switch(
                  value: visible,
                  onChanged: (bool v) => state.setVisible(v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 用 Wrap 而不是 Row：窗口窄的时候芯片会换行，不会被挤爆。
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _Chip(
                icon: state.encrypted ? Icons.lock_rounded : Icons.lock_open_rounded,
                label: state.encrypted ? '加密传输' : '未加密',
                tint: state.encrypted ? WispColors.success : WispColors.warning,
              ),
              _Chip(
                icon: Icons.fingerprint_rounded,
                label: state.settings.fingerprint.length >= 8
                    ? state.settings.fingerprint.substring(0, 8).toUpperCase()
                    : state.settings.fingerprint.toUpperCase(),
                tint: WispColors.accent(context),
              ),
              if (state.settings.hasUsername)
                _Chip(
                  icon: Icons.person_outline_rounded,
                  label: state.settings.username,
                  tint: WispColors.teal,
                ),
              Text(
                'v1.0',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final Color color = active ? WispColors.success : WispColors.warning;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.6, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeInOut,
      builder: (BuildContext context, double t, Widget? _) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: active ? 0.9 : 0.5),
          boxShadow: <BoxShadow>[
            BoxShadow(color: color.withValues(alpha: 0.35 * t), blurRadius: 8, spreadRadius: 2),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.tint});

  final IconData icon;
  final String label;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: tint),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: tint,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
