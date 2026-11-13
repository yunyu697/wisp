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
      //
      // 但**启动阶段不能静音**：_LaunchView 自己的淡入也依赖 ticker，
      // 静默启动（窗口一直藏着）时它会被冻在 opacity 0，用户从托盘打开
      // 就只看到一片白。ready 之前一律放行，就绪后再按窗口可见性收敛。
      builder: (BuildContext context, Widget? child) => TickerMode(
        enabled: !state.ready || state.mainWindowVisible,
        child: child ?? const SizedBox.shrink(),
      ),
      // 这里刻意不用 AnimatedSwitcher：启动页 → 主界面若发生在其过渡期间
      // 且 ticker 恰好被静音（静默启动 / 托盘恢复的时序竞态），切换会永远
      // 卡在全透明的那一帧，整个客户区就是一片白。直接条件渲染没有中间态。
      home: state.ready ? const HomeShell() : const _LaunchView(),
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
