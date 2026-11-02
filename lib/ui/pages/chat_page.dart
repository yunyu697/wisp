import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/utils/format.dart';
import '../../models/device.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../widgets/device_tile.dart';

/// 聊天页：气泡 + 输入框 + 一键发送剪贴板。
///
/// 这是整个"发剪贴板"需求的落点：内容以消息的形式直接送到对端，
/// **不写临时文件、不走文件传输、不进传输记录**。
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.peerKey});

  final String peerKey;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  AppState? _state;
  bool _sending = false;

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
  void dispose() {
    // 离开就取消"正在看"，之后到达的消息重新计未读。
    _state?.leaveChat();
    _input.dispose();
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
    if (device == null || !device.messageCapable) {
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
    if (device == null || !device.messageCapable) {
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
              Navigator.of(context).maybePop();
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

    return Scaffold(
      body: Column(
        children: <Widget>[
          _header(context, state, conversation, device),
          Expanded(
            child: _messageList(context, state, conversation, device),
          ),
          _composer(context, state, device),
        ],
      ),
    );
  }

  Widget _header(
    BuildContext context,
    AppState state,
    Conversation? conversation,
    WispDevice? device,
  ) {
    final String status;
    if (device == null) {
      status = '不在线，等它重新出现在附近';
    } else if (!device.messageCapable) {
      status = '${device.modelLabel} · 不支持发消息';
    } else {
      status = '${device.modelLabel} · ${device.ip}';
    }

    return Container(
      decoration: BoxDecoration(
        color: WispColors.surface(context).withValues(alpha: 0.92),
        border: Border(bottom: BorderSide(color: WispColors.line(context))),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 8, 8),
          child: Row(
            children: <Widget>[
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded, size: 22),
                color: WispColors.secondaryText(context),
              ),
              DeviceAvatar(kind: device?.kind ?? DeviceKind.unknown, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      conversation?.peerAlias ?? '未知设备',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
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
              IconButton(
                tooltip: '删除对话',
                onPressed: () => _confirmDelete(state),
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                color: WispColors.secondaryText(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _messageList(
    BuildContext context,
    AppState state,
    Conversation? conversation,
    WispDevice? device,
  ) {
    final List<ChatMessage> messages = conversation?.messages ?? <ChatMessage>[];
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
    final double maxWidth = MediaQuery.sizeOf(context).width * 0.72;
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
          GestureDetector(
            onLongPress: () => _copy(message.text),
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                style: TextStyle(fontSize: 14.5, height: 1.45, color: textColor),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                Format.clock(message.time),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(fontSize: 10.5),
              ),
              if (outgoing) ...<Widget>[
                const SizedBox(width: 6),
                if (message.status == MessageStatus.sending)
                  Text(
                    '发送中…',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(fontSize: 10.5),
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
    final bool online = device != null && device.messageCapable;
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
                          device == null
                              ? '对方不在附近，消息发不出去'
                              : '对方不是 Wisp（或版本太旧），只能收发文件',
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
                                : WispColors.secondaryText(context).withValues(alpha: 0.5),
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
                        const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
                        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
                      },
                      child: TextField(
                        controller: _input,
                        enabled: online,
                        minLines: 1,
                        maxLines: 5,
                        onChanged: (_) => setState(() {}),
                        style: Theme.of(context).textTheme.bodyMedium,
                        decoration: InputDecoration(
                          hintText: online ? '输入消息…' : '对方不在线',
                          isDense: true,
                          filled: true,
                          fillColor: WispColors.surfaceAlt(context),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                    '点左边图标直接发送剪贴板 · Ctrl + Enter 发送',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: WispColors.secondaryText(context).withValues(alpha: 0.8),
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
