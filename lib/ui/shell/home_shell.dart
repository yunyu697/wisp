import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/design/app_motion.dart';
import '../../core/utils/format.dart';
import '../../models/transfer.dart';
import '../../services/receiver_service.dart';
import '../../state/app_state.dart';
import '../pages/contacts_page.dart';
import '../pages/history_page.dart';
import '../pages/messages_page.dart';
import '../pages/send_page.dart';
import '../pages/settings_page.dart';
import '../responsive.dart';
import '../widgets/device_tile.dart';
import '../widgets/gradient_button.dart';
import '../widgets/wisp_bottom_nav.dart';

/// 主容器：四个页面（会话 / 联系人 / 文件 / 设置）+ 磨砂底栏 + 接收请求的拦截层。
///
/// 导航照设计稿只有四项：设备发现收进「会话 → 新消息」，发文件通过
/// 拖拽 / 重发触发的「发送」路由页完成，不再各占导航位。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  // 默认落在「会话」（index 0）：打开就是三栏聊天主场。
  final PageController _pageController = PageController(initialPage: 0);
  int _index = 0;
  int _composeTick = 0;
  bool _sendRouteOpen = false;
  int _unread = 0;
  AppState? _state;
  bool _sheetOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppState state = context.read<AppState>();
    if (!identical(state, _state)) {
      _state?.removeListener(_onStateChanged);
      _state = state..addListener(_onStateChanged);
    }
  }

  @override
  void dispose() {
    _state?.removeListener(_onStateChanged);
    _pageController.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    final AppState? state = _state;
    if (state == null) return;

    if (state.incoming != null && !_sheetOpen) {
      _sheetOpen = true;
      final IncomingRequest request = state.incoming!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openIncoming(request));
    }

    // 请求在别处（悬浮球气泡/系统通知）被处理掉了：把还开着的确认弹层收掉。
    //
    // 这里有两条**必须**遵守的约束，否则会把整个应用 pop 空（黑屏）：
    //
    // 1. 标志必须**当场**置 false，不能等 await 返回。
    //    `_openIncoming` 要等 showModalBottomSheet 的 Future 完成才把 _sheetOpen
    //    置回 false，而一次接收流程里 notifyListeners 会连着来好几趟
    //    （清 incoming、开传输、第一帧进度…），每一趟都看到 _sheetOpen==true
    //    就会调度好几次 pop。
    // 2. pop 之前必须确认"还有东西可 pop"。
    //    第一次 pop 关掉弹层后 canPop 就变成 false（只剩 home 这一条路由），
    //    第二次 pop 会把 home 也弹掉：Navigator 空了，框架什么都不画，
    //    窗口客户区整块纯黑，而且再也回不来。
    if (state.incoming == null && _sheetOpen) {
      _sheetOpen = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final NavigatorState nav = Navigator.of(context);
        if (!nav.canPop()) return;
        nav.pop();
      });
    }

    if (state.banner != null) {
      final String message = state.banner!;
      // 不能在通知回调里再触发一次通知，放到下一帧处理。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _state?.clearBanner();
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      });
    }

    // 未读角标：只在数字真的变了才重建，别让传输进度那 100ms 一次的
    // notifyListeners 把整个外壳也跟着重画。
    if (state.unreadMessages != _unread) {
      _unread = state.unreadMessages;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }

    // 有内容进待发清单了（拖拽 / 历史重发）：打开发送路由页。
    // 只在计数变化时响应，避免每次 notify 都把用户拽过去。
    // 发送不再占导航位（设计稿四项：会话 / 联系人 / 文件 / 设置）。
    if (state.composeTick != _composeTick) {
      _composeTick = state.composeTick;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_sendRouteOpen) _openSendRoute();
      });
    }
  }

  void _openSendRoute() {
    _sendRouteOpen = true;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(builder: (BuildContext _) => const SendPage()),
        )
        .whenComplete(() => _sendRouteOpen = false);
  }

  Future<void> _openIncoming(IncomingRequest request) async {
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (BuildContext sheetContext) => _IncomingSheet(request: request),
    );
    _sheetOpen = false;
    // 用户直接下滑关掉时，视为拒绝，避免对端一直等。
    if (!request.isResolved && mounted) {
      _state?.rejectIncoming();
    }
  }

  void _select(int index) {
    setState(() => _index = index);
    _pageController.animateToPage(
      index,
      duration: WispMotion.page,
      curve: WispMotion.enter,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget pages = PageView(
      controller: _pageController,
      physics: const NeverScrollableScrollPhysics(),
      onPageChanged: (int index) => setState(() => _index = index),
      children: const <Widget>[
        MessagesPage(),
        ContactsPage(),
        HistoryPage(),
        SettingsPage(),
      ],
    );

    // 竖屏：底部导航 + 单栏，和手机一致。
    if (!isWideLayout(context)) {
      return Scaffold(
        body: SafeArea(bottom: false, child: pages),
        bottomNavigationBar:
            WispBottomNav(index: _index, onChanged: _select, unread: _unread),
      );
    }

    // 横屏 / 宽窗口：侧边导航 + 内容区。
    // 一般页面限宽居中（kMaxContentWidth）避免被拉伸；但会话页在真正的宽
    // 桌面窗口上要铺满，才放得下「会话栏 / 消息流 / 身份卡」三栏。
    final bool fullBleed = _index == 0 && isThreeColumnLayout(context);
    return Scaffold(
      body: Row(
        children: <Widget>[
          WispNavRail(index: _index, onChanged: _select, unread: _unread),
          Expanded(
            child: SafeArea(
              child: fullBleed
                  ? pages
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
                        child: pages,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 收到传输请求：先讲清楚"谁、发什么、多大"，再让用户决定。
class _IncomingSheet extends StatelessWidget {
  const _IncomingSheet({required this.request});

  final IncomingRequest request;

  @override
  Widget build(BuildContext context) {
    final AppState state = context.read<AppState>();
    final int total = request.files.fold(0, (int sum, TransferFile f) => sum + f.size);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: WispColors.success.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '有人要发东西给你',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: WispColors.success,
                ),
              ),
            ),
            const SizedBox(height: 16),
            DeviceAvatar(kind: request.sender.kind, size: 56),
            const SizedBox(height: 10),
            Text(
              request.sender.alias,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '${request.files.length} 个文件 · ${Format.bytes(total)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 18),
            // 列表是唯一可伸缩的一块：窗口被拉矮时先压它，而不是把下面的
            // 「接收 / 拒绝」挤出屏幕。以前这里是固定 maxHeight，窗口一矮
            // 整个 Column 就溢出，按钮被窗口底边切掉——用户反馈的
            // "缩小窗口时通知的按钮被遮挡"就是这个。
            Flexible(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 190),
                decoration: BoxDecoration(
                  color: WispColors.surfaceAlt(context),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  itemCount: request.files.length,
                  itemBuilder: (BuildContext context, int index) {
                    final TransferFile file = request.files[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            FileKind.iconFor(file.name),
                            size: 16,
                            color: FileKind.colorFor(file.name),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              file.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                          Text(Format.bytes(file.size),
                              style: Theme.of(context).textTheme.labelMedium),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: <Widget>[
                // 两个按钮严格等宽等高（桌面端弹层曾因 flex 不均被吐槽）。
                Expanded(
                  child: GradientButton(
                    label: '接收',
                    icon: Icons.download_rounded,
                    onPressed: () {
                      Navigator.of(context).pop();
                      state.acceptIncoming();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 54,
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        state.rejectIncoming();
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: WispColors.secondaryText(context),
                        side: BorderSide(color: WispColors.line(context)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(27)),
                      ),
                      child: const Text('拒绝'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
