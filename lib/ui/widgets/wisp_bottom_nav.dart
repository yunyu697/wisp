import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/design/app_motion.dart';
import '../../state/app_state.dart';

class WispNavItem {
  const WispNavItem(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// 四个导航项，底栏与侧栏共用，保证两套导航完全一致。
///
/// 信息架构照设计稿（design/01-main-desktop.png）：
/// 会话 / 联系人 / 文件 / 设置。设备发现收进「会话 → 新消息」，
/// 发文件走会话与传输流程，不再各占一个导航位。
const List<WispNavItem> wispNavItems = <WispNavItem>[
  WispNavItem('会话', Icons.chat_bubble_rounded),
  WispNavItem('联系人', Icons.people_alt_rounded),
  WispNavItem('文件', Icons.folder_rounded),
  WispNavItem('设置', Icons.settings_rounded),
];

/// 「会话」在导航里的位置，未读角标挂在它上面。
const int kMessagesNavIndex = 0;

/// 底栏尺寸常量。
///
/// 图标 + 文字这一组内容高 [_contentHeight]，高亮块高 [_pillHeight]，
/// 两者都居中于 [_barHeight]，因此高亮块必然完整包住图标和文字。
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

  /// 「会话」上的未读数，0 表示不显示角标。
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
                    Icon(item.icon, size: _iconSize, color: color),
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

/// 侧边导航：宽窗口下替代底部栏，尺寸照设计稿——
/// 76px 竖条，60×54 圆角导航块，图标 + 10.5px 文字，选中浅底 + 主色；
/// 栏底是「我」的头像（用户名首字）。
class WispNavRail extends StatelessWidget {
  const WispNavRail({
    super.key,
    required this.index,
    required this.onChanged,
    this.unread = 0,
  });

  final int index;
  final ValueChanged<int> onChanged;

  /// 「会话」上的未读数，0 表示不显示角标。
  final int unread;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color surface = isDark ? const Color(0xFF111A1B) : Colors.white;
    final Color accent = WispColors.accent(context);
    final Color idle = WispColors.secondaryText(context);
    // 从主题派生标签样式，保证继承全局字体（否则中文会回退成方框）。
    final TextStyle labelBase = Theme.of(context).textTheme.labelMedium ?? const TextStyle();
    final String me = context.watch<AppState>().settings.alias.trim();

    return Container(
      width: 76,
      decoration: BoxDecoration(
        color: surface.withValues(alpha: isDark ? 0.86 : 0.82),
        border: Border(right: BorderSide(color: WispColors.line(context))),
      ),
      child: SafeArea(
        child: Column(
          children: <Widget>[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(13),
                child: Image.asset(
                  'assets/icon/wisp_icon_1024.png',
                  width: 34,
                  height: 34,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
            const SizedBox(height: 10),
            for (int i = 0; i < wispNavItems.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: _RailCell(
                  item: wispNavItems[i],
                  selected: i == index,
                  badge: i == kMessagesNavIndex ? unread : 0,
                  accent: accent,
                  idle: idle,
                  labelStyle: labelBase,
                  onTap: () {
                    if (i == index) return;
                    HapticFeedback.selectionClick();
                    onChanged(i);
                  },
                ),
              ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Tooltip(
                message: me.isEmpty ? '我的设备' : me,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: WispColors.brandGradient,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    me.isEmpty ? 'W' : me.characters.first.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      height: 1,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 60×54 圆角导航块：设计稿 rail 的最小单元。
class _RailCell extends StatelessWidget {
  const _RailCell({
    required this.item,
    required this.selected,
    required this.badge,
    required this.accent,
    required this.idle,
    required this.labelStyle,
    required this.onTap,
  });

  final WispNavItem item;
  final bool selected;
  final int badge;
  final Color accent;
  final Color idle;
  final TextStyle labelStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = selected ? accent : idle;
    return Tooltip(
      message: item.label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: AnimatedContainer(
            duration: WispMotion.fast,
            curve: WispMotion.emphasis,
            width: 60,
            height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: selected ? accent.withValues(alpha: 0.10) : Colors.transparent,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Icon(item.icon, size: 20, color: color),
                    if (badge > 0)
                      Positioned(right: -9, top: -5, child: _NavBadge(count: badge)),
                  ],
                ),
                const SizedBox(height: 3),
                SizedBox(
                  height: 12,
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle.copyWith(
                      fontSize: 10.5,
                      height: 1.1,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: color,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
