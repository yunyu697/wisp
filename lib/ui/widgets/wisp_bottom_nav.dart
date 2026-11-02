import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/design/app_colors.dart';
import '../../core/design/app_motion.dart';

class WispNavItem {
  const WispNavItem(this.label, this.icon, this.activeIcon);
  final String label;
  final IconData icon;
  final IconData activeIcon;
}

/// 五个导航项，底栏与侧边栏共用，保证两套导航完全一致。
///
/// 「消息」排在「附近」之后、「发送」之前：发现设备 → 说句话，是 IM 里
/// 最自然的顺序；文件发送反而是更"重"的动作，排在后面不抢位置。
const List<WispNavItem> wispNavItems = <WispNavItem>[
  WispNavItem('附近', Icons.radar_rounded, Icons.radar_rounded),
  WispNavItem('消息', Icons.forum_rounded, Icons.forum_rounded),
  WispNavItem('发送', Icons.arrow_upward_rounded, Icons.arrow_upward_rounded),
  WispNavItem('记录', Icons.history_rounded, Icons.history_rounded),
  WispNavItem('设置', Icons.tune_rounded, Icons.tune_rounded),
];

/// 「消息」在导航里的位置，未读角标挂在它上面。
const int kMessagesNavIndex = 1;

/// 底栏尺寸常量。
///
/// 图标 + 文字这一组内容高 [_contentHeight]，高亮块高 [_pillHeight]，
/// 两者都居中于 [_barHeight]，因此高亮块必然完整包住图标和文字。
/// 以后改字号或图标大小，间距会自动跟着走，不会再出现"高亮切到字"的情况。
const double _barHeight = 62;
const double _iconSize = 22;
const double _labelGap = 3;
const double _labelHeight = 12;
const double _contentHeight = _iconSize + _labelGap + _labelHeight;
const double _pillHeight = 46;
const double _pillRadius = 16;

/// 磨砂底栏 + 滑动指示块。
///
/// 指示块用 AnimatedPositioned 跟随索引，图标颜色同步补间；
/// 切换时给一次极轻的触感反馈，符合 iOS 的交互预期。
class WispBottomNav extends StatelessWidget {
  const WispBottomNav({
    super.key,
    required this.index,
    required this.onChanged,
    this.unread = 0,
  });

  final int index;
  final ValueChanged<int> onChanged;

  /// 「消息」上的未读数，0 表示不显示角标。
  final int unread;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color surface = isDark ? const Color(0xFF111A1B) : Colors.white;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        child: Container(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom > 0 ? 0.0 : 8.0),
          decoration: BoxDecoration(
            color: surface.withValues(alpha: isDark ? 0.86 : 0.82),
            border: Border(top: BorderSide(color: WispColors.line(context))),
          ),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double itemWidth = constraints.maxWidth / wispNavItems.length;
              return SizedBox(
                height: _barHeight,
                child: Stack(
                  children: <Widget>[
                    AnimatedPositioned(
                      duration: WispMotion.base,
                      curve: WispMotion.enter,
                      left: itemWidth * index + 10,
                      top: (_barHeight - _pillHeight) / 2,
                      width: itemWidth - 20,
                      height: _pillHeight,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(_pillRadius),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: <Color>[
                              WispColors.teal.withValues(alpha: isDark ? 0.30 : 0.12),
                              WispColors.tealLight.withValues(alpha: isDark ? 0.24 : 0.10),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: List<Widget>.generate(wispNavItems.length, (int i) {
                        final bool selected = i == index;
                        return Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (i == index) return;
                              HapticFeedback.selectionClick();
                              onChanged(i);
                            },
                            child: _NavCell(
                              item: wispNavItems[i],
                              selected: selected,
                              badge: i == kMessagesNavIndex ? unread : 0,
                            ),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NavCell extends StatelessWidget {
  const _NavCell({required this.item, required this.selected, this.badge = 0});

  final WispNavItem item;
  final bool selected;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final Color accent = WispColors.accent(context);
    final Color idle = WispColors.secondaryText(context);
    final Color color = selected ? accent : idle;

    return SizedBox(
      height: _barHeight,
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          // 内容高度写死为 _contentHeight，位置就完全可预测——
          // 高亮块按同样的中心对齐，必然完整包住图标和文字。
          height: _contentHeight,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              AnimatedScale(
                scale: selected ? 1.0 : 0.92,
                duration: WispMotion.fast,
                curve: WispMotion.emphasis,
                child: Stack(
                  // 角标故意探出图标边界，不能被裁掉。
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Icon(selected ? item.activeIcon : item.icon, size: _iconSize, color: color),
                    if (badge > 0)
                      Positioned(
                        right: -8,
                        top: -5,
                        child: _NavBadge(count: badge),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: _labelGap),
              AnimatedDefaultTextStyle(
                duration: WispMotion.fast,
                // 从主题派生，保证字体/字重跟全局一致（而不是写死一个裸 TextStyle）。
                style: (Theme.of(context).textTheme.labelMedium ?? const TextStyle()).copyWith(
                  fontSize: 10.5,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: color,
                  letterSpacing: 0,
                ),
                child: SizedBox(
                  height: _labelHeight,
                  child: Text(item.label, textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 未读角标。超过 99 显示 99+，否则数字会撑宽到盖住旁边的图标。
class _NavBadge extends StatelessWidget {
  const _NavBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final String label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 15),
      height: 15,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: WispColors.danger,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WispColors.surface(context), width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          height: 1,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

/// 侧边导航：横屏 / 宽窗口下替代底部栏。
///
/// 竖条放在屏幕左侧，顶部放一个 logo，下面是等宽的导航项。
/// 选中项用 Material 3 的 indicator 高亮（和底栏的渐变胶囊视觉一致：
/// 都是"淡色块 + 主色图标/文字"），切换逻辑与底栏共用 onChanged。
class WispNavRail extends StatelessWidget {
  const WispNavRail({
    super.key,
    required this.index,
    required this.onChanged,
    this.unread = 0,
  });

  final int index;
  final ValueChanged<int> onChanged;

  /// 「消息」上的未读数，0 表示不显示角标。
  final int unread;

  /// 侧栏图标 + 未读角标（只挂在「消息」上）。
  Widget _railIcon(IconData icon, int i) {
    if (i != kMessagesNavIndex || unread <= 0) return Icon(icon);
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Icon(icon),
        Positioned(right: -10, top: -6, child: _NavBadge(count: unread)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color surface = isDark ? const Color(0xFF111A1B) : Colors.white;
    final Color accent = WispColors.accent(context);
    // 从主题派生标签样式，保证继承全局字体（否则中文会回退成方框）。
    final TextStyle labelBase = Theme.of(context).textTheme.labelMedium ?? const TextStyle();

    return Container(
      width: 88,
      decoration: BoxDecoration(
        color: surface.withValues(alpha: isDark ? 0.86 : 0.82),
        border: Border(right: BorderSide(color: WispColors.line(context))),
      ),
      child: SafeArea(
        child: Column(
          children: <Widget>[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(13),
                child: Image.asset(
                  'assets/icon/wisp_icon_1024.png',
                  width: 36,
                  height: 36,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: NavigationRail(
                backgroundColor: Colors.transparent,
                selectedIndex: index,
                onDestinationSelected: (int i) {
                  if (i == index) return;
                  HapticFeedback.selectionClick();
                  onChanged(i);
                },
                labelType: NavigationRailLabelType.all,
                indicatorColor: accent.withValues(alpha: 0.12),
                indicatorShape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                selectedIconTheme: IconThemeData(color: accent, size: 22),
                unselectedIconTheme:
                    IconThemeData(color: WispColors.secondaryText(context), size: 22),
                selectedLabelTextStyle: labelBase.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  letterSpacing: 0.2,
                ),
                unselectedLabelTextStyle: labelBase.copyWith(
                  color: WispColors.secondaryText(context),
                  fontWeight: FontWeight.w500,
                  fontSize: 11,
                ),
                destinations: <NavigationRailDestination>[
                  for (int i = 0; i < wispNavItems.length; i++)
                    NavigationRailDestination(
                      icon: _railIcon(wispNavItems[i].icon, i),
                      selectedIcon: _railIcon(wispNavItems[i].activeIcon, i),
                      label: Text(wispNavItems[i].label),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
