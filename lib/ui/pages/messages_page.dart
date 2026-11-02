import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/utils/format.dart';
import '../../models/device.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../widgets/device_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/wisp_card.dart';
import 'chat_page.dart';

/// 消息页：会话列表。
///
/// 形态照着 IM 来——每行一台设备，右边是最后一条消息和时间，未读挂角标。
/// 和「记录」页的区别要一眼看出来：这里聊的是话，那里记的是文件。
class MessagesPage extends StatelessWidget {
  const MessagesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
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
/// 不支持消息的设备也列出来，但置灰并写清原因——直接隐藏会让人以为
/// "这台设备没被发现"。
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
                        final bool capable = device.messageCapable;
                        return Opacity(
                          opacity: capable ? 1 : 0.45,
                          child: ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            leading: DeviceAvatar(kind: device.kind, size: 38),
                            title: Text(device.alias),
                            subtitle: Text(
                              capable ? device.modelLabel : '${device.modelLabel} · 不支持发消息',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            onTap: capable
                                ? () => Navigator.of(context).pop(device)
                                : null,
                          ),
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
