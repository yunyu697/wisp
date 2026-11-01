import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/design/app_colors.dart';
import 'core/design/app_theme.dart';
import 'state/app_state.dart';
import 'ui/shell/home_shell.dart';

class WispApp extends StatelessWidget {
  const WispApp({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    return MaterialApp(
      title: 'Wisp',
      debugShowCheckedModeBanner: false,
      theme: WispTheme.light(),
      darkTheme: WispTheme.dark(),
      themeMode: state.settings.themeMode,
      // 窗口藏起来（收进托盘 / 最小化 / 静默启动）时把 ticker 全部静音。
      //
      // 主界面那圈"正在寻找附近的设备"雷达是无限循环动画，窗口不可见时
      // Flutter 引擎照样按 60fps 出帧，空转吃掉 25~50% CPU。这类"没人看还在画"
      // 的动画只能在根部统一掐掉——让每个页面各自判断窗口状态，新加一个动画
      // 就会漏一个，而且漏了也没人发现。
      builder: (BuildContext context, Widget? child) => TickerMode(
        enabled: state.mainWindowVisible,
        child: child ?? const SizedBox.shrink(),
      ),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 420),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: state.ready ? const HomeShell() : const _LaunchView(),
      ),
    );
  }
}

/// 启动页：图标轻微放大淡入，等状态加载完就交给主界面。
class _LaunchView extends StatefulWidget {
  const _LaunchView();

  @override
  State<_LaunchView> createState() => _LaunchViewState();
}

class _LaunchViewState extends State<_LaunchView> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  )..forward();

  late final Animation<double> _scale = Tween<double>(begin: 0.86, end: 1).animate(
    CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.7, curve: Curves.easeOut),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? WispColors.darkBg : WispColors.lightBg,
      body: Center(
        child: FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: _scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: Image.asset(
                    'assets/icon/wisp_icon_1024.png',
                    width: 96,
                    height: 96,
                    filterQuality: FilterQuality.high,
                  ),
                ),
                const SizedBox(height: 18),
                Text('Wisp', style: Theme.of(context).textTheme.displayMedium),
                const SizedBox(height: 6),
                Text(
                  '只在近处发生的传递',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
