import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/utils/format.dart';
import '../../core/utils/pickers.dart';
import '../../models/contact.dart';
import '../../models/device.dart';
import '../../models/message.dart';
import '../../models/transfer.dart';
import '../../state/app_state.dart';
import '../flows/send_flow.dart';
import '../widgets/attachment_bundle.dart';
import '../widgets/device_sheets.dart';
import '../widgets/device_tile.dart';
import '../widgets/gradient_button.dart';

/// 聊天页：气泡 + 输入框 + 一键发送剪贴板。
///
/// 这是整个"发剪贴板"需求的落点：内容以消息的形式直接送到对端，
/// **不写临时文件、不走文件传输、不进传输记录**。
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.peerKey,
    this.embedded = false,
    this.onClose,
  });

  final String peerKey;

  /// true = 嵌在分栏主场的消息流里：不包 Scaffold、不显示返回键。
  /// 窄屏仍走 MaterialPageRoute，保持「退出会话 = pop」的语义。
  final bool embedded;

  /// 三栏里点「关闭会话」：清空选中态，下次进来默认折叠。
  final VoidCallback? onClose;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _input = TextEditingController();
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  AppState? _state;
  bool _sending = false;

  /// 会话内搜索：头部换成一个搜索框，消息列按关键词过滤。
  /// 退出会话（didUpdateWidget / dispose）时必须复位，否则 A 会话的搜索词
  /// 会带进 B 会话，用户看到一片「没有找到」。
  bool _searching = false;

  /// 每条消息独立的「多文件卡已展开」状态，只由点击增删。
  /// 切换会话（didUpdateWidget）或退出重进（父层用 ValueKey 重建）时清空，
  /// 新消息、滚动、rebuild 都不会动它。
  final Set<String> _expandedBundles = <String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppState state = context.read<AppState>();
    if (identical(state, _state)) return;
    _state = state;
    // enterChat 会 notifyListeners，直接在依赖变更期间调用等于在构建期
    // 触发重建；放到下一帧最稳。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _state?.enterChat(widget.peerKey);
    });
  }

  @override
  void didUpdateWidget(ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerKey != widget.peerKey) {
      // 切换会话必须清空展开态，否则 A 会话展开的卡会串到 B 会话里。
      _expandedBundles.clear();
      _input.clear();
      _search.clear();
      _searching = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _state?.enterChat(widget.peerKey);
      });
    }
  }

  @override
  void dispose() {
    // 离开就取消"正在看"，之后到达的消息重新计未读。
    _state?.leaveChat();
    _input.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  WispDevice? _device(AppState state) {
    final Conversation? conversation = state.conversationOf(widget.peerKey);
    if (conversation == null) return null;
    return state.deviceForConversation(conversation);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    // 列表是 reverse 的，offset 0 就是最底部。
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _send() async {
    final AppState? state = _state;
    if (state == null || _sending) return;
    final String text = _input.text;
    if (text.trim().isEmpty) return;
    final WispDevice? device = _device(state);
    if (device == null) {
      _toast('对方不在线，消息发不出去');
      return;
    }
    setState(() => _sending = true);
    _input.clear();
    final String? error = await state.sendText(device, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (error != null) _toast(error);
    _scrollToBottom();
  }

  /// 一键发送剪贴板。
  ///
  /// 长文本（超过 2000 字）先给一眼预览再发：剪贴板里躺着一整份日志时，
  /// 直接甩过去对方会很难受，而用户自己也未必知道复制的是什么。
  Future<void> _sendClipboard() async {
    final AppState? state = _state;
    if (state == null || _sending) return;
    final WispDevice? device = _device(state);
    if (device == null) {
      _toast('对方不在线，消息发不出去');
      return;
    }
    final String? text = await state.clipboardText();
    if (!mounted) return;
    if (text == null) {
      _toast('剪贴板里没有文字');
      return;
    }
    if (text.length > 2000) {
      final bool confirmed = await _confirmLongText(text) ?? false;
      if (!mounted || !confirmed) return;
    }
    setState(() => _sending = true);
    final String? error = await state.sendClipboard(device);
    if (!mounted) return;
    setState(() => _sending = false);
    if (error != null) {
      _toast(error);
    } else {
      _toast('已发送剪贴板内容（${text.length} 字）');
    }
    _scrollToBottom();
  }

  /// composer 附件发送（设计稿 03 的「+」）：文件选择器挑文件，
  /// 走标准文件通道直发给当前会话对端，不动待发清单。
  /// 传输完成后统一账本会把文件追加成本会话的附件消息。
  Future<void> _attachAndSend() async {
    final AppState? state = _state;
    if (state == null || _sending) return;
    final WispDevice? device = _device(state);
    if (device == null) {
      _toast('对方不在线，文件发不出去');
      return;
    }
    final List<TransferFile> picked = await Pickers.pickFiles();
    if (picked.isEmpty || !mounted) return;
    setState(() => _sending = true);
    final String? error = await state.sendTo(device, files: picked);
    if (!mounted) return;
    setState(() => _sending = false);
    if (error != null) {
      _toast(error);
    } else {
      _toast('已发送 ${picked.length} 个文件');
    }
    _scrollToBottom();
  }

  Future<bool?> _confirmLongText(String text) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: WispColors.surface(dialogContext),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('发送剪贴板内容？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('剪贴板里有 ${text.length} 个字符，确认要发出去吗？',
                style: Theme.of(dialogContext).textTheme.bodyMedium),
            const SizedBox(height: 12),
            Container(
              width: double.maxFinite,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: WispColors.surfaceAlt(dialogContext),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                text.length <= 240 ? text : '${text.substring(0, 240)}…',
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('发送'),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _toast('已复制');
  }

  Future<void> _resend(AppState state, ChatMessage message) async {
    final WispDevice? device = _device(state);
    if (device == null) {
      _toast('对方不在线，消息发不出去');
      return;
    }
    final String? error = await state.resendMessage(device, message);
    if (!mounted) return;
    if (error != null) _toast(error);
  }

  void _confirmDelete(AppState state) {
    final Conversation? conversation = state.conversationOf(widget.peerKey);
    if (conversation == null) return;
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: WispColors.surface(dialogContext),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('删除这段对话'),
        content: Text('会删掉和 ${conversation.peerAlias} 的全部聊天记录，不影响任何文件。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              state.deleteConversation(widget.peerKey);
              // 嵌在分栏主场里时没有可 pop 的会话路由：直接清空选中态。
              // 以前无条件 maybePop 会一路弹到根路由（黑屏的老坑）。
              if (widget.embedded) {
                widget.onClose?.call();
              } else {
                Navigator.of(context).maybePop();
              }
            },
            child: const Text('删除', style: TextStyle(color: WispColors.danger)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final Conversation? conversation = state.conversationOf(widget.peerKey);
    final WispDevice? device = _device(state);

    final Widget body = Column(
      children: <Widget>[
        _header(context, state, conversation, device),
        Expanded(
          child: _messageList(context, state, conversation, device),
        ),
        _composer(context, state, device),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(body: body);
  }

  /// 头部按设计稿 01：头像 + 名称（可带「免确认接收」徽标）+ 状态行，
  /// 右侧三个圆角方按钮「搜索 / 联系人 / ⋯」。
  ///
  /// 搜索时整行换成搜索框——不叠在标题上，避免窄窗口里标题被挤成两个字。
  Widget _header(
    BuildContext context,
    AppState state,
    Conversation? conversation,
    WispDevice? device,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: WispColors.surface(context).withValues(alpha: 0.92),
        border: Border(bottom: BorderSide(color: WispColors.line(context))),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 8, 8),
          child: _searching
              ? _searchBar(context, conversation)
              : _titleRow(context, state, conversation, device),
        ),
      ),
    );
  }

  Widget _titleRow(
    BuildContext context,
    AppState state,
    Conversation? conversation,
    WispDevice? device,
  ) {
    final Contact? contact = state.contactOf(widget.peerKey);
    final String fingerprint = contact?.id ?? device?.fingerprint ?? '';
    final bool trusted = fingerprint.trim().isNotEmpty &&
        state.settings.trustedFingerprints.contains(fingerprint);
    final String status = device == null
        ? '不在线 · 等它重新出现在附近'
        : '在线 · ${device.ip}'
            '${fingerprint.isEmpty ? '' : ' · 稳定标识 ${device.shortFingerprint}'}';

    return Row(
      children: <Widget>[
        if (!widget.embedded)
          IconButton(
            tooltip: '返回会话列表',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_rounded, size: 22),
            color: WispColors.secondaryText(context),
          )
        else
          const SizedBox(width: 4),
        DeviceAvatar(
          kind: device?.kind ?? contact?.kind ?? DeviceKind.unknown,
          size: 34,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      conversation?.peerAlias ?? '未知设备',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (trusted) ...<Widget>[
                    const SizedBox(width: 8),
                    const _TrustPill(),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        _HeaderAction(
          icon: Icons.search_rounded,
          tooltip: '搜索这段对话',
          onTap: _startSearch,
        ),
        const SizedBox(width: 6),
        _HeaderAction(
          icon: Icons.people_alt_outlined,
          tooltip: '联系人资料',
          onTap: () => _showProfile(state, conversation, device),
        ),
        const SizedBox(width: 6),
        _moreMenu(context, state, device),
      ],
    );
  }

  /// 「⋯」：危险动作收进菜单，不再在头部占一个孤立图标。
  Widget _moreMenu(BuildContext context, AppState state, WispDevice? device) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      color: WispColors.surface(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      itemBuilder: (BuildContext menuContext) => <PopupMenuEntry<String>>[
        if (device != null)
          const PopupMenuItem<String>(
            value: 'device',
            child: Text('设备详情'),
          ),
        const PopupMenuItem<String>(
          value: 'delete',
          child: Text('删除这段对话'),
        ),
        if (widget.embedded)
          const PopupMenuItem<String>(
            value: 'close',
            child: Text('关闭会话'),
          ),
      ],
      onSelected: (String value) {
        if (value == 'device' && device != null) {
          showDeviceSheet(context, state, device);
        } else if (value == 'delete') {
          _confirmDelete(state);
        } else if (value == 'close') {
          widget.onClose?.call();
        }
      },
      child: const _HeaderActionBox(icon: Icons.more_horiz_rounded),
    );
  }

  void _startSearch() {
    setState(() {
      _searching = true;
      _search.clear();
    });
  }

  void _stopSearch() {
    setState(() {
      _searching = false;
      _search.clear();
    });
  }

  Widget _searchBar(BuildContext context, Conversation? conversation) {
    final List<ChatMessage> all = conversation?.messages ?? <ChatMessage>[];
    final String query = _search.text.trim();
    final int hits = _filter(all).length;

    return Row(
      children: <Widget>[
        const SizedBox(width: 8),
        Icon(
          Icons.search_rounded,
          size: 18,
          color: WispColors.secondaryText(context),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _search,
            autofocus: true,
            onChanged: (String _) => setState(() {}),
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: '搜索这段对话',
              hintStyle: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        if (query.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              '$hits / ${all.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        TextButton(
          onPressed: _stopSearch,
          child: const Text('取消', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  /// 会话内搜索：正文和附件名都算命中；没在搜索或查询为空时原样返回。
  List<ChatMessage> _filter(List<ChatMessage> messages) {
    final String query = _search.text.trim().toLowerCase();
    if (!_searching || query.isEmpty) return messages;
    return messages.where((ChatMessage message) {
      if (message.text.toLowerCase().contains(query)) return true;
      for (final ChatAttachment attachment in message.attachments) {
        if (attachment.name.toLowerCase().contains(query)) return true;
      }
      return false;
    }).toList();
  }

  /// 联系人资料：在线离线都能看，在线才给「发文件」。
  Future<void> _showProfile(
    AppState state,
    Conversation? conversation,
    WispDevice? device,
  ) {
    final Contact? contact = state.contactOf(widget.peerKey);
    final String alias = conversation?.peerAlias ?? contact?.alias ?? '未知设备';
    final String fingerprint = contact?.id ?? device?.fingerprint ?? '';
    final bool trusted = fingerprint.trim().isNotEmpty &&
        state.settings.trustedFingerprints.contains(fingerprint);
    final String status = device == null
        ? '不在线 · 等它重新出现在附近'
        : '在线 · ${device.modelLabel} · ${device.ip}';

    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: WispColors.surface(context),
      constraints: const BoxConstraints(maxWidth: 480),
      // 默认弹层最高只到屏高 9/16，资料卡有五六行 + 两个按钮，会被压到只剩
      // 滚动条；放开高度后仍受下面的 82% 限高与 SingleChildScrollView 兜底。
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      // 矮窗口（800×600 或手机横屏）里内容会超过弹层高度，底部「删除」会被
      // 挤出屏幕点不到。限高 + 可滚动，别让按钮够不着。
      builder: (BuildContext sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DeviceAvatar(
                kind: device?.kind ?? contact?.kind ?? DeviceKind.unknown,
                size: 62,
              ),
              const SizedBox(height: 12),
              Text(
                alias,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(sheetContext).textTheme.headlineMedium,
              ),
              const SizedBox(height: 4),
              Text(status, style: Theme.of(sheetContext).textTheme.bodySmall),
              const SizedBox(height: 18),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: WispColors.surfaceAlt(sheetContext),
                  border: Border.all(color: WispColors.line(sheetContext)),
                ),
                child: Column(
                  children: <Widget>[
                    _ProfileRow(
                      label: '稳定标识',
                      value: fingerprint.isEmpty
                          ? '未识别'
                          : device?.shortFingerprint ?? _shortId(fingerprint),
                    ),
                    const SizedBox(height: 10),
                    _ProfileRow(
                      label: '免确认接收',
                      value: trusted ? '已开启' : '未开启',
                    ),
                    if (device != null) ...<Widget>[
                      const SizedBox(height: 10),
                      _ProfileRow(label: '协议版本', value: device.version),
                      const SizedBox(height: 10),
                      _ProfileRow(
                        label: '传输加密',
                        value: device.https ? '已开启' : '未开启',
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (device != null)
                GradientButton(
                  label: '给 ${conversation?.peerAlias ?? '这台设备'} 发文件',
                  icon: Icons.arrow_upward_rounded,
                  onPressed: () async {
                    Navigator.of(sheetContext).pop();
                    await startSendFlow(context, state, device);
                  },
                ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  _confirmDelete(state);
                },
                child: const Text(
                  '删除这段对话',
                  style: TextStyle(color: WispColors.danger, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 指纹只展示前 8 位：64 位十六进制在一行里既读不出也记不住。
  String _shortId(String fingerprint) {
    final String flat = fingerprint.replaceAll(':', '').toUpperCase();
    return flat.length <= 8 ? flat : flat.substring(0, 8);
  }

  Widget _messageList(
    BuildContext context,
    AppState state,
    Conversation? conversation,
    WispDevice? device,
  ) {
    final List<ChatMessage> all = conversation?.messages ?? <ChatMessage>[];
    final List<ChatMessage> messages = _filter(all);
    if (messages.isEmpty && all.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.search_off_rounded,
                size: 30,
                color: WispColors.secondaryText(context).withValues(alpha: 0.6),
              ),
              const SizedBox(height: 12),
              Text(
                '没有找到「${_search.text.trim()}」',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 6),
              Text(
                '换个词试试，消息正文和文件名都能搜',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 30,
                color: WispColors.secondaryText(context).withValues(alpha: 0.6),
              ),
              const SizedBox(height: 12),
              Text(
                '和 ${conversation?.peerAlias ?? '这台设备'} 的对话还没有开始',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              Text(
                '点左下角的按钮，把剪贴板里的一段话直接发过去',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }

    final List<Object> items = _buildItems(messages);
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final Object item = items[items.length - 1 - index];
        if (item is String) return _dayLabel(context, item);
        return _bubble(context, state, item as ChatMessage);
      },
    );
  }

  /// 摊平成「日期标题 + 气泡」的混合列表（时间正序）。
  List<Object> _buildItems(List<ChatMessage> messages) {
    final List<Object> items = <Object>[];
    String? currentDay;
    for (final ChatMessage message in messages) {
      final String day = Format.dayLabel(message.time);
      if (day != currentDay) {
        currentDay = day;
        items.add(day);
      }
      items.add(message);
    }
    return items;
  }

  Widget _dayLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: WispColors.surfaceAlt(context),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: WispColors.secondaryText(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bubble(BuildContext context, AppState state, ChatMessage message) {
    final bool outgoing = message.isOutgoing;
    // 宽窗口上限 560：只按屏宽的 72% 算，2000px 的窗口上气泡会拉成一条
    // 1400px 的长条，眼睛根本跟不上换行。
    final double room = MediaQuery.sizeOf(context).width * 0.72;
    final double maxWidth = room > 560 ? 560 : room;
    final bool hasText = message.text.trim().isNotEmpty;
    final bool expanded = _expandedBundles.contains(message.id);
    final Color textColor = outgoing
        ? Colors.white
        : (Theme.of(context).brightness == Brightness.dark
            ? WispColors.darkText
            : WispColors.lightText);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment:
            outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          if (hasText)
            GestureDetector(
              onLongPress: () => _copy(message.text),
              child: Container(
                constraints: BoxConstraints(maxWidth: maxWidth),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  gradient: outgoing ? WispColors.brandGradient : null,
                  color: outgoing ? null : WispColors.surfaceAlt(context),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(outgoing ? 18 : 6),
                    bottomRight: Radius.circular(outgoing ? 6 : 18),
                  ),
                ),
                child: Text(
                  message.text,
                  style:
                      TextStyle(fontSize: 14.5, height: 1.45, color: textColor),
                ),
              ),
            ),
          if (message.hasAttachments) ...<Widget>[
            if (hasText) const SizedBox(height: 6),
            AttachmentBundle(
              attachments: message.attachments,
              expanded: expanded,
              outgoing: outgoing,
              onToggle: () => setState(() {
                // 只由点击改变：新消息 / 滚动 / rebuild 都不动这个 Set。
                if (expanded) {
                  _expandedBundles.remove(message.id);
                } else {
                  _expandedBundles.add(message.id);
                }
              }),
            ),
          ],
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                Format.clock(message.time),
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(fontSize: 10.5),
              ),
              if (outgoing) ...<Widget>[
                const SizedBox(width: 6),
                if (message.status == MessageStatus.sending)
                  Text(
                    '发送中…',
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(fontSize: 10.5),
                  )
                else if (message.failed)
                  GestureDetector(
                    onTap: () => _resend(state, message),
                    child: Text(
                      '发送失败，点这里重试',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            fontSize: 10.5,
                            color: WispColors.danger,
                          ),
                    ),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _composer(BuildContext context, AppState state, WispDevice? device) {
    // 文字/剪贴板入口对所有 LocalSend 设备可用：不再有 messageCapable 门控。
    final bool online = device != null;
    final bool canSend = online && !_sending;

    return Container(
      decoration: BoxDecoration(
        color: WispColors.surface(context),
        border: Border(top: BorderSide(color: WispColors.line(context))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (!online)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.cloud_off_rounded,
                          size: 14, color: WispColors.warning),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '对方不在附近，消息发不出去',
                          style: TextStyle(
                            fontSize: 12,
                            color: WispColors.secondaryText(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  // 「+」= 附件（文件选择器，走文件通道直发）；设计稿 03 的输入区。
                  Tooltip(
                    message: '发送文件',
                    child: Material(
                      color: WispColors.surfaceAlt(context),
                      borderRadius: BorderRadius.circular(15),
                      child: InkWell(
                        onTap: canSend ? _attachAndSend : null,
                        borderRadius: BorderRadius.circular(15),
                        child: Padding(
                          padding: const EdgeInsets.all(11),
                          child: Icon(
                            Icons.add_rounded,
                            size: 20,
                            color: canSend
                                ? WispColors.secondaryText(context)
                                : WispColors.secondaryText(context)
                                    .withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '发送剪贴板内容',
                    child: Material(
                      color: WispColors.accent(context).withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(15),
                      child: InkWell(
                        onTap: canSend ? _sendClipboard : null,
                        borderRadius: BorderRadius.circular(15),
                        child: Padding(
                          padding: const EdgeInsets.all(11),
                          child: Icon(
                            Icons.content_paste_rounded,
                            size: 20,
                            color: canSend
                                ? WispColors.accent(context)
                                : WispColors.secondaryText(context)
                                    .withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: CallbackShortcuts(
                      bindings: <ShortcutActivator, VoidCallback>{
                        // Enter 留给换行，Ctrl/Cmd + Enter 才发送：
                        // 粘贴进来的代码片段经常是多行的，Enter 直接发出去会很烦。
                        const SingleActivator(LogicalKeyboardKey.enter,
                            control: true): _send,
                        const SingleActivator(LogicalKeyboardKey.enter,
                            meta: true): _send,
                      },
                      child: TextField(
                        controller: _input,
                        enabled: online,
                        minLines: 1,
                        maxLines: 5,
                        onChanged: (_) => setState(() {}),
                        style: Theme.of(context).textTheme.bodyMedium,
                        decoration: InputDecoration(
                          hintText: online ? '发消息、粘贴图片…' : '对方不在线',
                          isDense: true,
                          filled: true,
                          fillColor: WispColors.surfaceAlt(context),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _sendButton(context, canSend),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '「+」发文件 · 剪贴板图标发文字 · Ctrl + Enter 发送',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: WispColors.secondaryText(context)
                          .withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sendButton(BuildContext context, bool enabled) {
    return GestureDetector(
      onTap: enabled ? _send : null,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: enabled ? WispColors.brandGradient : null,
          color: enabled ? null : WispColors.surfaceAlt(context),
        ),
        child: Icon(
          Icons.arrow_upward_rounded,
          size: 20,
          color: enabled ? Colors.white : WispColors.secondaryText(context),
        ),
      ),
    );
  }
}

/// 设计稿 01 聊天头右侧的圆角方按钮外观（34×34 · r12 · 1px 描边）。
class _HeaderActionBox extends StatelessWidget {
  const _HeaderActionBox({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: WispColors.line(context)),
      ),
      child: Icon(icon, size: 18, color: WispColors.secondaryText(context)),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: _HeaderActionBox(icon: icon),
      ),
    );
  }
}

/// 「免确认接收」小徽标：这是白名单状态，不是身份认证。
class _TrustPill extends StatelessWidget {
  const _TrustPill();

  @override
  Widget build(BuildContext context) {
    final Color accent = WispColors.accent(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.verified_user_rounded, size: 11, color: accent),
          const SizedBox(width: 3),
          Text(
            '免确认接收',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const Spacer(),
        Text(value, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}
