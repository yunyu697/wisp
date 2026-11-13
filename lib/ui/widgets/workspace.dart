import 'package:flutter/material.dart';

import '../../core/design/app_colors.dart';

/// 「工作台」左栏容器：固定宽度、surface 底色、右侧 1px 分隔线。
///
/// 与「消息」页三栏的左会话栏同构——三页重做后都走这套骨架，
/// 左栏放"我是谁 / 要发什么 / 概览"，右栏放内容主体。
class WispAside extends StatelessWidget {
  const WispAside({super.key, required this.child, this.width = 300});

  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          color: WispColors.surface(context),
          border: Border(right: BorderSide(color: WispColors.line(context))),
        ),
        child: child,
      ),
    );
  }
}

/// 面板 / 页面标题：主标题 + 可选副标题 + 右侧操作。
///
/// [compact] 为 true 时标题降到 titleMedium，用于左栏这种窄栏。
class WispPanelHeader extends StatelessWidget {
  const WispPanelHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 16, 10),
    this.compact = false,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: compact
                      ? Theme.of(context).textTheme.titleMedium
                      : Theme.of(context).textTheme.titleLarge,
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// 分组小标题：11px 次级色、可带右侧计数。与「消息」页的分区标题同款。
class WispSectionLabel extends StatelessWidget {
  const WispSectionLabel({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(4, 14, 4, 8),
  });

  final String title;
  final String? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                color: WispColors.secondaryText(context),
              ),
            ),
          ),
          if (trailing != null)
            Text(
              trailing!,
              style: TextStyle(
                fontSize: 11,
                color: WispColors.secondaryText(context).withValues(alpha: 0.8),
              ),
            ),
        ],
      ),
    );
  }
}
