import 'dart:io';

import 'package:flutter/services.dart';

/// 主窗口 + 悬浮球的当前状态，用于决定通知走哪条通道。
class DesktopWindowState {
  const DesktopWindowState({
    required this.visible,
    required this.active,
    required this.ballEnabled,
    required this.ballExpanded,
    required this.ballSnapped,
  });

  /// 拿不到原生状态时的兜底值。
  ///
  /// 注意这里刻意**不**当成"用户在看着主窗口"：拿不到状态就静默不打扰，
  /// 等于把通知吞掉——用户反馈过"要第二次才会出现"，最怕的就是这种
  /// 一次被吞掉、第二次状态正常才弹出来。宁可多弹一次，也不能一声不吭。
  static const DesktopWindowState unknown = DesktopWindowState(
    visible: false,
    active: false,
    ballEnabled: false,
    ballExpanded: false,
    ballSnapped: false,
  );

  final bool visible;
  final bool active;
  final bool ballEnabled;
  final bool ballExpanded;
  final bool ballSnapped;

  /// 主窗口开着且正被使用 —— 只有这种情况才不打扰桌面。
  bool get userIsLooking => visible && active;
}

/// 与桌面原生层通信的小通道。
///
/// 管三类事：
/// 1. 托盘（点关闭最小化到托盘、图标闪烁）；
/// 2. 系统通知（右下角 toast）；
/// 3. 悬浮球与气泡（开关悬浮球、气泡的询问/进度/完成三种状态）。
/// 非桌面平台没有实现，调用会被静默忽略。
class DesktopService {
  const DesktopService._();

  static const MethodChannel _channel = MethodChannel('wisp/desktop');

  /// 该平台有没有原生悬浮球实现。
  ///
  /// **只有 Windows 有**：它是一个自绘的分层窗口（`WS_EX_LAYERED` +
  /// `UpdateLayeredWindow`），大小、吸附、气泡都在 runner 的 C++ 里画。
  ///
  /// macOS 的 `wisp/desktop` 通道只实现了窗口/菜单栏那部分，`setFloatingBall`
  /// 直接回 `FlutterMethodNotImplemented`；Linux 根本没人实现；Android 也没有
  /// 对得上的悬浮窗形态。设置页据此隐藏开关——**显示一个点了没反应的开关，
  /// 比不显示更糟**（用户会以为功能坏了，反复开关）。
  static bool get supportsFloatingBall =>
      _supportsFloatingBallOverride ?? Platform.isWindows;

  static bool? _supportsFloatingBallOverride;

  /// 仅供测试注入平台能力（默认跟随当前平台）。
  static void debugSetSupportsFloatingBall(bool? value) =>
      _supportsFloatingBallOverride = value;

  /// 原生层推回来的事件。AppState 启动时注册一次。
  static void Function(String event, Map<Object?, Object?> args)? _eventHandler;

  /// 点关闭按钮时是否最小化到系统托盘。
  static Future<void> setMinimizeToTray(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setMinimizeToTray', <String, bool>{'enabled': enabled});
    } on MissingPluginException {
      // 该平台没有实现这个能力，忽略。
    } on PlatformException {
      // 原生层报错不应该影响主流程。
    }
  }

  /// 启动时要不要显示主窗口（静默启动传 false）。
  ///
  /// 原生层把首帧画好之后**先不显示**，等这个调用表态——设置只有 Dart 侧知道，
  /// 原生层自己猜会先闪一下窗口再藏起来。原生侧有 1.5s 兜底：Dart 一直不说话
  /// 就照常显示，绝不会把窗口永久藏住。
  static Future<void> setStartupVisible(bool visible) async {
    try {
      await _channel.invokeMethod<void>(
          'setStartupVisible', <String, bool>{'visible': visible});
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 把主窗口显示出来并前置（托盘/悬浮球点击时用）。
  static Future<void> showWindow() async {
    try {
      await _channel.invokeMethod<void>('showWindow');
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 启动一个本地安装程序（自动更新用）。
  ///
  /// Windows 必须走原生 ShellExecuteW（runas）：安装器要求管理员权限，
  /// CreateProcess 直接启动带 admin 清单的 exe 会报 ERROR_ELEVATION_REQUIRED，
  /// 而这是唯一会正常弹 UAC 的路径。
  /// 原生侧只放行 .exe，防止这个口子被用来开任意文件。
  static Future<bool> runInstaller(String path, {List<String> args = const <String>[]}) async {
    try {
      final bool? ok = await _channel.invokeMethod<bool>('runInstaller', <String, dynamic>{
        'path': path,
        'args': args.join(' '),
      });
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 当前平台是否支持托盘/悬浮球等桌面能力。
  static Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 主窗口当前是否可见（可见时收到请求只弹应用内弹层，不打扰桌面）。
  ///
  /// **拿不到状态时必须返回 false**，不能返回 true。
  ///
  /// 这里的"保守处理"很容易写反：返回 true 等于告诉调用方"用户正看着主
  /// 窗口"，于是桌面通知被判定为多余而**直接吞掉**——用户看到的就是
  /// "通知要下一次才出现"。拿不到状态时宁可多弹一次桌面通知，也不要静默。
  ///
  /// （通知分流实际走的是 [windowState]，这个方法保留给"只关心可见性"
  /// 的场景，语义必须与之一致。）
  static Future<bool> isWindowVisible() async {
    try {
      return await _channel.invokeMethod<bool>('isWindowVisible') ?? false;
    } on MissingPluginException {
      return false; // 无法判断时不打扰桌面。
    } on PlatformException {
      return false;
    }
  }

  /// 通知分流需要的完整桌面状态。
  ///
  /// 只判断"可见"是不够的：窗口可见但被别的程序盖住时，用户根本看不到应用内
  /// 弹层，这时必须弹桌面通知。所以还要知道它是不是当前激活窗口。
  static Future<DesktopWindowState> windowState() async {
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('windowState');
      if (raw == null) return DesktopWindowState.unknown;
      return DesktopWindowState(
        visible: raw['visible'] == true,
        active: raw['active'] == true,
        ballEnabled: raw['ballEnabled'] == true,
        ballExpanded: raw['ballExpanded'] == true,
        ballSnapped: raw['ballSnapped'] == true,
      );
    } on MissingPluginException {
      return DesktopWindowState.unknown;
    } on PlatformException {
      return DesktopWindowState.unknown;
    }
  }

  /// 三类桌面窗口的可见性与矩形。自测入口用它断言"通知真的弹出来了"。
  static Future<Map<String, Object?>> debugWindows() async {
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('debugWindows');
      if (raw == null) return <String, Object?>{};
      return raw.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v));
    } on MissingPluginException {
      return <String, Object?>{};
    } on PlatformException {
      return <String, Object?>{};
    }
  }

  /// 自测用：把主窗口隐藏/显示出来（复现托盘态收到请求的场景）。
  static Future<void> debugSetMainVisible(bool visible) async {
    try {
      await _channel.invokeMethod<void>(
          'debugSetMainVisible', <String, bool>{'visible': visible});
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 自测用：把主窗口置前（模拟用户点回主窗口）。
  static Future<void> debugFocusMain() async {
    try {
      await _channel.invokeMethod<void>('debugFocusMain');
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 自测用：把焦点挪到别的窗口（模拟主窗口开着但用户忙别的）。
  static Future<void> debugBlurMain() async {
    try {
      await _channel.invokeMethod<void>('debugBlurMain');
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 自测用：抓某个窗口（main/toast/bubble）的屏幕像素，返回 {ok, mean, dark}。
  /// mean=平均亮度，dark=接近纯黑的像素占比。原生层会同时存一张 PNG。
  static Future<Map<String, Object?>> debugCapture(String target) async {
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>(
              'debugCapture', <String, String>{'target': target});
      if (raw == null) return <String, Object?>{};
      return raw.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v));
    } on MissingPluginException {
      return <String, Object?>{};
    } on PlatformException {
      return <String, Object?>{};
    }
  }

  /// 自测用：悬浮球当前不透明度系数。0.25=静置变淡，1=全不透明。
  /// 用来客观验证"创建后静置必须自己变淡"（不依赖鼠标事件）。
  static Future<double> debugBallDim() async {
    try {
      return await _channel.invokeMethod<double>('debugBallDim') ?? 1.0;
    } on MissingPluginException {
      return 1.0;
    } on PlatformException {
      return 1.0;
    }
  }

  /// 托盘图标闪烁（有新传输请求时）。
  static Future<void> setTrayFlashing(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setTrayFlashing', <String, bool>{'enabled': enabled});
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 桌面浮层的真实状态（通知卡 / 气泡）。
  ///
  /// 返回 {toast: {...}, bubble: {...}}，每项含 visible/active/drawn 与屏幕矩形。
  /// `drawn` 表示原生层确实把像素画上去了——只看 visible 会被"窗口在、
  /// 内容空"骗过去。
  static Future<Map<String, Object?>> surfaceStatus() async {
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('surfaceStatus');
      if (raw == null) return <String, Object?>{};
      return raw.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v));
    } on MissingPluginException {
      return <String, Object?>{};
    } on PlatformException {
      return <String, Object?>{};
    }
  }

  /// 桌面右下角通知卡片。mode：0 询问接收 / 1 传输进度 / 2 传输完成。
  static Future<void> showToast(
    String title,
    String body, {
    int mode = bubbleAsk,
    String progress = '',
  }) async {
    try {
      await _channel.invokeMethod<void>('showToast', <String, dynamic>{
        'title': title,
        'body': body,
        'mode': mode,
        'progress': progress,
      });
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 更新已显示的通知卡片（进度/完成切换），并顺延存活时间。
  static Future<void> updateToast(
    String body, {
    int mode = bubbleProgress,
    String progress = '',
  }) async {
    try {
      await _channel.invokeMethod<void>('updateToast', <String, dynamic>{
        'body': body,
        'mode': mode,
        'progress': progress,
      });
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 收起通知卡片。
  static Future<void> hideToast() async {
    try {
      await _channel.invokeMethod<void>('hideToast');
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 服务守护状态：0=未安装 1=已安装未运行 2=运行中。
  static Future<int> serviceStatus() async {
    try {
      final Object? status = await _channel.invokeMethod<Object?>('serviceStatus');
      return status is int ? status : 0;
    } on MissingPluginException {
      return 0;
    } on PlatformException {
      return 0;
    }
  }

  /// 安装并启动守护服务（会弹一次 UAC 授权）。失败（取消授权）返回 false。
  static Future<bool> installService() async {
    try {
      final Object? ok = await _channel.invokeMethod<Object?>('installService');
      return ok is bool && ok;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 重启守护服务（会弹一次 UAC 授权）。未安装或失败返回 false。
  static Future<bool> restartService() async {
    try {
      final Object? ok = await _channel.invokeMethod<Object?>('restartService');
      return ok is bool && ok;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 停止并卸载守护服务（会弹一次 UAC 授权）。失败返回 false。
  static Future<bool> uninstallService() async {
    try {
      final Object? ok =
          await _channel.invokeMethod<Object?>('uninstallService');
      return ok is bool && ok;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 显示/隐藏桌面悬浮球。hoverDelayMs：把手悬停多久自动展开。
  /// savedPos：上次记忆的球位置（物理像素），启用时恢复到原地。
  static Future<void> setFloatingBall(
    bool enabled, {
    int hoverDelayMs = 300,
    int? savedPosX,
    int? savedPosY,
    bool savedSnapped = false,
    int savedEdge = -1,
  }) async {
    try {
      await _channel.invokeMethod<void>('setFloatingBall', <String, dynamic>{
        'enabled': enabled,
        'hoverDelayMs': hoverDelayMs,
        if (savedPosX != null && savedPosY != null) ...<String, dynamic>{
          'x': savedPosX,
          'y': savedPosY,
          'snapped': savedSnapped,
          'edge': savedEdge,
        },
      });
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 有新传输请求时唤醒悬浮球（显示 + 提示动画）。
  static Future<void> showBallAlert() async {
    try {
      await _channel.invokeMethod<void>('showBallAlert');
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 通知流程结束：吸附状态的悬浮球缩回把手。
  static Future<void> collapseBall() async {
    try {
      await _channel.invokeMethod<void>('collapseBall');
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 气泡/卡片消息的四种模式，与 C++ 层的 kCardMode* 一一对应。
  static const int bubbleAsk = 0;
  static const int bubbleProgress = 1;
  static const int bubbleDone = 2;

  /// 取消/中断提示：卡片只显示标题和正文，没有按钮与进度条，
  /// 原生层 3 秒后自动收起（ToastLifetimeMs）。
  static const int bubbleCanceled = 3;

  /// 纯通知（收到一条消息）：和 [bubbleCanceled] 是同一套渲染——没有按钮、
  /// 没有进度条、到点自己收——只是语义不同，所以单独给个名字。
  /// C++ 侧按数值判断，两个常量必须是同一个值。
  static const int bubbleInfo = 3;

  /// 在悬浮球旁边弹出气泡。mode：0 询问接收 / 1 传输进度 / 2 传输完成。
  static Future<void> showBubble(
    String title,
    String body, {
    int mode = bubbleAsk,
    String progress = '',
  }) async {
    try {
      await _channel.invokeMethod<void>('showBubble', <String, dynamic>{
        'title': title,
        'body': body,
        'mode': mode,
        'progress': progress,
      });
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 更新已显示气泡的内容（传输进度用，避免闪烁重建窗口）。
  static Future<void> updateBubble(
    String body, {
    int mode = bubbleProgress,
    String progress = '',
  }) async {
    try {
      await _channel.invokeMethod<void>('updateBubble', <String, dynamic>{
        'body': body,
        'mode': mode,
        'progress': progress,
      });
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 收起气泡。
  static Future<void> hideBubble() async {
    try {
      await _channel.invokeMethod<void>('hideBubble');
    } on MissingPluginException {
      // 忽略。
    } on PlatformException {
      // 忽略。
    }
  }

  /// 注册原生事件回调。事件名：
  /// * onBallClicked — 用户点了悬浮球；
  /// * onBallPosition — 拖动结束后原生层上报球的最终位置；
  /// * onBubbleAction — 用户在气泡上点了按钮，args 里有 action
  ///   （accept / dismiss / openFolder）；
  /// * onFilesDropped — 文件被拖进主窗口，args['paths'] 是本地路径列表；
  /// * onToastClicked — 用户点了系统通知；
  /// * onBubbleTimeout — 气泡超时自动消失。
  static void setEventHandler(void Function(String event, Map<Object?, Object?> args)? handler) {
    _eventHandler = handler;
    _channel.setMethodCallHandler(handler == null
        ? null
        : (MethodCall call) async {
            final void Function(String, Map<Object?, Object?>)? sink = _eventHandler;
            if (sink != null) {
              final Object? args = call.arguments;
              sink(
                call.method,
                args is Map<Object?, Object?> ? args : const <Object?, Object?>{},
              );
            }
          });
  }
}
