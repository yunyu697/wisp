import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/utils/format.dart';
import '../../models/contact.dart';
import '../../models/device.dart';
import '../../state/app_state.dart';
import '../widgets/device_sheets.dart';
import '../widgets/device_tile.dart' show DeviceAvatar;
import '../widgets/empty_state.dart';
import '../widgets/workspace.dart';

/// 联系人页：按 fingerprint 留存的身份列表。
///
/// 分三组：置顶/保留、临时会话（有过往来但还没保留）、归档（默认折叠）。
/// 点任意一台都直接进它的会话；在线设备长按可以看详情、直接发文件。
class ContactsPage extends StatelessWidget {
  const ContactsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();

    final List<Contact> kept = <Contact>[];
    final List<Contact> temporary = <Contact>[];
    final List<Contact> archived = <Contact>[];
    for (final Contact contact in state.contacts) {
      if (contact.isArchived) {
        archived.add(contact);
      } else if (contact.isKept || contact.pinned) {
        kept.add(contact);
      } else {
        temporary.add(contact);
      }
    }
    kept.sort(_byPinnedThenActivity);
    temporary.sort(_byActivity);
    archived.sort(_byActivity);
    final int online = state.contacts
        .where((Contact c) => deviceForContact(state, c.id) != null)
        .length;

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: WispPanelHeader(
            title: '联系人',
            subtitle: state.contacts.isEmpty
                ? '互传过的设备都会记在这里'
                : '${state.contacts.length} 位联系人 · $online 台在线',
            compact: true,
            padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
          ),
        ),
        if (state.contacts.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.people_alt_rounded,
              title: '还没有联系人',
              subtitle: '去「会话」页点右上角「新消息」，\n'
                  '选一台附近的设备开始第一次互传；\n'
                  '设备按指纹记住，换 Wi-Fi 也认得出。',
            ),
          )
        else ...<Widget>[
          _group(context, state, '保留的联系人', kept, collapsed: false),
          _group(context, state, '临时会话', temporary, collapsed: false),
          _group(context, state, '已归档', archived, collapsed: true),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Text(
                '联系人按设备指纹记住，换网络也能找回同一段会话；\n'
                '归档只收起列表，聊天记录一条不删。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ],
    );
  }

  static int _byActivity(Contact a, Contact b) =>
      b.lastActive.compareTo(a.lastActive);

  static int _byPinnedThenActivity(Contact a, Contact b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    return _byActivity(a, b);
  }

  Widget _group(
    BuildContext context,
    AppState state,
    String title,
    List<Contact> list, {
    required bool collapsed,
  }) {
    if (list.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return _ContactGroupSliver(
      title: title,
      contacts: list,
      defaultCollapsed: collapsed,
      state: state,
    );
  }
}

/// 一组联系人：分组标题 + 折叠开关 + 设备卡列表。
class _ContactGroupSliver extends StatefulWidget {
  const _ContactGroupSliver({
    required this.title,
    required this.contacts,
    required this.defaultCollapsed,
    required this.state,
  });

  final String title;
  final List<Contact> contacts;
  final bool defaultCollapsed;
  final AppState state;

  @override
  State<_ContactGroupSliver> createState() => _ContactGroupSliverState();
}

class _ContactGroupSliverState extends State<_ContactGroupSliver> {
  late bool _collapsed = widget.defaultCollapsed;

  @override
  Widget build(BuildContext context) {
    return SliverMainAxisGroup(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _collapsed = !_collapsed),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
              child: Row(
                children: <Widget>[
                  // WispSectionLabel 内部自带 Expanded，必须给它有界宽度，
                  // 所以这里用 Expanded 包住而不是直接平铺进 Row。
                  Expanded(
                    child: WispSectionLabel(
                      title: widget.title,
                      trailing: '${widget.contacts.length}',
                      padding: EdgeInsets.zero,
                    ),
                  ),
                  Icon(
                    _collapsed
                        ? Icons.expand_more_rounded
                        : Icons.expand_less_rounded,
                    size: 18,
                    color: WispColors.secondaryText(context),
                  ),
                ],
              ),
              ),
            ),
          ),
        ),
        if (!_collapsed)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            sliver: SliverList.separated(
              itemCount: widget.contacts.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(height: 10),
              itemBuilder: (BuildContext context, int index) => _ContactCard(
                contact: widget.contacts[index],
                state: widget.state,
              ),
            ),
          ),
      ],
    );
  }
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({required this.contact, required this.state});

  final Contact contact;
  final AppState state;

  /// 从联系人卡打开会话：没聊过天的联系人先建会话；离线又没会话的给一句提示。
  void _openConversation(AppState state) {
    if (state.conversationOf(contact.id) == null) {
      final WispDevice? device = deviceForContact(state, contact.id);
      if (device == null) {
        state.banner = '这台设备不在线，也没有往来记录；等它出现在同一网络再聊。';
        return;
      }
      state.openChat(device);
    }
    state.requestOpenConversation(contact.id);
  }

  @override
  Widget build(BuildContext context) {
    final WispDevice? device = deviceForContact(state, contact.id);
    final bool online = device != null;
    final String presence = online
        ? '在线 · ${device.ip}'
        : '最近活跃 ${Format.relative(contact.lastActive)}';
    final String meta = online
        ? device.modelLabel
        : contact.knownIps.isEmpty
            ? '未在同一网络'
            : '曾用网络 ${contact.knownIps.length} 个';

    return Material(
      color: WispColors.surface(context),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: () => _openConversation(state),
        onLongPress: () => _actions(context),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: WispColors.line(context)),
          ),
          child: Row(
            children: <Widget>[
              DeviceAvatar(kind: contact.kind),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            contact.alias,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (contact.pinned) ...<Widget>[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.push_pin_rounded,
                            size: 13,
                            color: WispColors.accent(context),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: <Widget>[
                        PresenceDot(online: online),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            '$presence · $meta',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                contact.shortId,
                style: TextStyle(
                  fontSize: 11,
                  color: WispColors.secondaryText(context).withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: () => _openConversation(state),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: WispColors.accent(context).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '发消息',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: WispColors.accent(context),
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

  Future<void> _actions(BuildContext context) async {
    final bool archived = contact.isArchived;
    final bool kept = contact.isKept || contact.pinned;
    await showModalBottomSheet<void>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (BuildContext sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.chat_bubble_rounded),
                title: const Text('打开会话'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openConversation(state);
                },
              ),
              if (deviceForContact(state, contact.id) != null)
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('设备详情'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    showDeviceSheet(
                      context,
                      state,
                      deviceForContact(state, contact.id)!,
                    );
                  },
                ),
              ListTile(
                leading: Icon(kept ? Icons.person_remove_rounded : Icons.person_add_rounded),
                title: Text(kept ? '取消保留' : '保留为联系人'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  state.keepContact(contact.id, keep: !kept);
                },
              ),
              ListTile(
                leading: Icon(archived ? Icons.unarchive_rounded : Icons.archive_rounded),
                title: Text(archived ? '取消归档' : '归档'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  state.archiveContact(contact.id, archive: !archived);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
