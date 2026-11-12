import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/utils/format.dart';
import '../../models/contact.dart';
import '../../models/device.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../widgets/device_tile.dart';
import '../responsive.dart';
import '../widgets/contact_inspector.dart';
import '../widgets/empty_state.dart';
import '../widgets/wisp_card.dart';
import 'chat_page.dart';

/// 消息页：会话列表。
///
/// 形态照着 IM 来——每行一台设备，右边是最后一条消息和时间，未读挂角标。
/// 和「记录」页的区别要一眼看出来：这里聊的是话，那里记的是文件。
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  /// 三栏主场里当前选中的会话。null = 中栏显示空态。
  /// 每次重新选中都用 ValueKey 重建 ChatPage，回到默认折叠。
  String? _selectedKey;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    // 真正的宽桌面窗口才铺三栏；窄窗口 / 移动端继续单栏 + push 会话页。
    if (isThreeColumnLayout(context)) return _threeColumn(context, state);
    final List<Conversation> conversations = state.conversations;

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('消息', style: Theme.of(context).textTheme.displayLarge),
                      const SizedBox(height: 4),
                      Text(
                        conversations.isEmpty
                            ? '和附近的设备说句话'
                            : '共 ${conversations.length} 个会话',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _pickDevice(context, state),
                  icon: const Icon(Icons.add_comment_outlined, size: 16),
                  label: const Text('新消息', style: TextStyle(fontSize: 14)),
                  style: TextButton.styleFrom(
                    foregroundColor: WispColors.accent(context),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (conversations.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.forum_rounded,
              title: '还没有消息',
              subtitle: '点右上角「新消息」，选一台附近的设备，\n'
                  '把剪贴板里的一段话直接发过去——不用存成文件。',
              action: GradientTextAction(
                label: '选择设备',
                onTap: () => _pickDevice(context, state),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
            sliver: SliverList.builder(
              itemCount: conversations.length,
              itemBuilder: (BuildContext context, int index) {
                final Conversation conversation = conversations[index];
                final WispDevice? device = state.deviceForConversation(conversation);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: StaggeredItem(
                    index: index,
                    child: _ConversationTile(
                      conversation: conversation,
                      kind: device?.kind ?? DeviceKind.unknown,
                      online: device != null,
                      onTap: () => _openChat(context, state, conversation),
                      onLongPress: () => _confirmDelete(context, state, conversation),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _threeColumn(BuildContext context, AppState state) {
    final String query = _query.trim().toLowerCase();
    final List<Conversation> all = state.conversations
        .where((Conversation c) =>
            query.isEmpty ||
            c.peerAlias.toLowerCase().contains(query) ||
            c.preview.toLowerCase().contains(query))
        .toList();

    final List<Conversation> kept = <Conversation>[];
    final List<Conversation> recent = <Conversation>[];
    final List<Conversation> temporary = <Conversation>[];
    for (final Conversation conversation in all) {
      final Contact? contact = state.contactOf(conversation.peerKey);
      if (contact != null && (contact.pinned || contact.isKept)) {
        kept.add(conversation);
      } else if (contact == null ||
          contact.isArchived ||
          conversation.messages.length <= 1) {
        temporary.add(conversation);
      } else {
        recent.add(conversation);
      }
    }

    return Row(
      // 右栏是 SingleChildScrollView，默认只按内容高度撑开，Row 会把这根
      // 短柱子垂直居中，导致身份卡底色上下各露一大截空白。整行拉伸后
      // 三栏都吃到同样的高度，左栏的 Expanded 列表也照样有界。
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 300,
          child: Container(
            decoration: BoxDecoration(
              color: WispColors.surface(context),
              border: Border(right: BorderSide(color: WispColors.line(context))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text('会话',
                            style: Theme.of(context).textTheme.headlineSmall),
                      ),
                      TextButton.icon(
                        onPressed: () => _pickDevice(context, state),
                        icon: const Icon(Icons.add_comment_outlined, size: 15),
                        label: const Text('新消息', style: TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                          foregroundColor: WispColors.accent(context),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  child: TextField(
                    onChanged: (String value) => setState(() => _query = value),
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      hintText: '搜索联系人、文件或内容',
                      hintStyle: TextStyle(
                          fontSize: 12,
                          color: WispColors.secondaryText(context)),
                      prefixIcon: Icon(Icons.search_rounded,
                          size: 18, color: WispColors.secondaryText(context)),
                      isDense: true,
                      filled: true,
                      fillColor: WispColors.surfaceAlt(context),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: all.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              '还没有会话。点「新消息」选一台附近的设备，文字、图片、文件都会留在这里。',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 12,
                                  height: 1.5,
                                  color: WispColors.secondaryText(context)),
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                          children: <Widget>[
                            if (kept.isNotEmpty) ...<Widget>[
                              _section(context, '置顶 · 保留的联系人', '${kept.length}'),
                              ...kept.map((Conversation c) => _row(context, state, c)),
                            ],
                            if (recent.isNotEmpty) ...<Widget>[
                              _section(context, '最近会话', '${recent.length}'),
                              ...recent.map((Conversation c) => _row(context, state, c)),
                            ],
                            if (temporary.isNotEmpty) ...<Widget>[
                              _section(context, '临时会话', '不占联系人位'),
                              ...temporary.map((Conversation c) => _row(context, state, c, faint: true)),
                            ],
                          ],
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                  child: Text(
                    '换一个局域网，这些聊天记录仍在。30 天无活动的临时会话自动归档，记录不删。',
                    style: TextStyle(
                        fontSize: 10.5,
                        height: 1.5,
                        color: WispColors.secondaryText(context)),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: _thread(context, state)),
        if (_selectedKey != null)
          SizedBox(
            width: 268,
            child: Container(
              decoration: BoxDecoration(
                color: WispColors.surfaceAlt(context).withValues(alpha: 0.35),
                border: Border(left: BorderSide(color: WispColors.line(context))),
              ),
              child: ContactInspector(peerKey: _selectedKey!),
            ),
          ),
      ],
    );
  }

  Widget _section(BuildContext context, String title, String trailing) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(title,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: WispColors.secondaryText(context))),
            ),
            Text(trailing,
                style: TextStyle(
                    fontSize: 10.5,
                    color: WispColors.secondaryText(context).withValues(alpha: 0.8))),
          ],
        ),
      );

  Widget _row(BuildContext context, AppState state, Conversation conversation,
      {bool faint = false}) {
    final WispDevice? device = state.deviceForConversation(conversation);
    final bool selected = _selectedKey == conversation.peerKey;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: selected
            ? WispColors.accent(context).withValues(alpha: 0.10)
            : null,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Opacity(
        opacity: faint ? 0.82 : 1,
        child: _ConversationTile(
          conversation: conversation,
          kind: device?.kind ?? DeviceKind.unknown,
          online: device != null,
          onTap: () => _openChat(context, state, conversation),
          onLongPress: () => _confirmDelete(context, state, conversation),
        ),
      ),
    );
  }

  Widget _thread(BuildContext context, AppState state) {
    final String? key = _selectedKey;
    if (key == null || state.conversationOf(key) == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.forum_outlined,
                size: 38,
                color: WispColors.secondaryText(context).withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text('选一个会话开始',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('文字、图片、文件都在同一条会话里',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
    }
    return ChatPage(
      // peerKey 变化时强制重建 State：展开态、输入框都不串场。
      key: ValueKey<String>(key),
      peerKey: key,
      embedded: true,
      onClose: () => setState(() => _selectedKey = null),
    );
  }

  void _openChat(BuildContext context, AppState state, Conversation conversation) {
    final WispDevice? device = state.deviceForConversation(conversation);
    // 设备不在线也允许进去看历史，只是发不出去——这比"点不动"更好理解。
    state.openChat(
      device ??
          WispDevice(
            alias: conversation.peerAlias,
            ip: conversation.peerIp,
            fingerprint: conversation.peerKey,
          ),
    );
    if (isThreeColumnLayout(context)) {
      setState(() => _selectedKey = conversation.peerKey);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => ChatPage(peerKey: conversation.peerKey),
      ),
    );
  }

  Future<void> _pickDevice(BuildContext context, AppState state) async {
    final AppState current = state;
    final WispDevice? picked = await showModalBottomSheet<WispDevice>(
      context: context,
      backgroundColor: WispColors.surface(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheetContext) => _DevicePicker(state: current),
    );
    if (picked == null || !context.mounted) return;
    current.openChat(picked);
    if (isThreeColumnLayout(context)) {
      setState(() => _selectedKey = picked.key);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => ChatPage(peerKey: picked.key),
      ),
    );
  }

  void _confirmDelete(BuildContext context, AppState state, Conversation conversation) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: WispColors.surface(dialogContext),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('删除与 ${conversation.peerAlias} 的会话'),
        content: const Text('会删掉这台设备上的聊天记录，不影响任何文件。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              state.deleteConversation(conversation.peerKey);
              Navigator.of(dialogContext).pop();
            },
            child: const Text('删除', style: TextStyle(color: WispColors.danger)),
          ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.kind,
    required this.online,
    required this.onTap,
    required this.onLongPress,
  });

  final Conversation conversation;
  final DeviceKind kind;
  final bool online;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final ChatMessage? last = conversation.last;
    final bool failed = last?.failed ?? false;
    return GestureDetector(
      onLongPress: onLongPress,
      child: WispCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        radius: 20,
        onTap: onTap,
        child: Row(
          children: <Widget>[
            Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                DeviceAvatar(kind: kind, size: 44),
                if (online)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        color: WispColors.success,
                        shape: BoxShape.circle,
                        border: Border.all(color: WispColors.surface(context), width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    conversation.peerAlias,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    conversation.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: failed
                              ? WispColors.danger
                              : WispColors.secondaryText(context),
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  last == null ? '' : Format.relative(last.time),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 5),
                if (conversation.unread > 0)
                  Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: WispColors.danger,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      conversation.unread > 99 ? '99+' : '${conversation.unread}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        height: 1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else
                  const SizedBox(height: 18),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 选一台设备开始新会话。
///
/// 文字/剪贴板消息走官方 LocalSend 的 preview 通道，对所有设备都可用——
/// 不再按 messageCapable 置灰或隐藏任何一台设备。
class _DevicePicker extends StatelessWidget {
  const _DevicePicker({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final List<WispDevice> devices = state.devices;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: WispColors.line(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text('选择设备', style: Theme.of(context).textTheme.titleMedium),
                  ),
                  Text(
                    devices.isEmpty ? '附近没有设备' : '${devices.length} 台在线',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Flexible(
              child: devices.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Text(
                        '先在「附近」页等设备出现，\n或者确认双方在同一网络。',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: devices.length,
                      itemBuilder: (BuildContext context, int index) {
                        final WispDevice device = devices[index];
                        return ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          leading: DeviceAvatar(kind: device.kind, size: 38),
                          title: Text(device.alias),
                          subtitle: Text(
                            device.modelLabel,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          onTap: () => Navigator.of(context).pop(device),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空态里的文字按钮（避免为了一个按钮引入整套 GradientButton 的高度）。
class GradientTextAction extends StatelessWidget {
  const GradientTextAction({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: WispColors.accent(context),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        ),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }
}
