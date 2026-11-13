import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/utils/contact_index.dart';
import '../../core/utils/format.dart';
import '../../models/contact.dart';
import '../../models/device.dart';
import '../../state/app_state.dart';
import '../widgets/device_sheets.dart';
import '../widgets/device_tile.dart' show DeviceAvatar;
import '../widgets/empty_state.dart';
import '../widgets/workspace.dart';

/// 联系人页：按设备指纹留存的身份列表，按拼音首字母 A–Z 分组。
///
/// 置顶联系人单独一组在最前，归档组默认折叠在末尾。右侧字母导航条点击
/// 直接滚到对应分组；分组位置由固定高度的 sliver 累加得出，不依赖懒构建
/// 的 widget 是否已经存在（SliverList 未滚到的组没有 context）。
class ContactsPage extends StatefulWidget {
  const ContactsPage({super.key});

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  final ScrollController _scroll = ScrollController();
  bool _archivedExpanded = false;

  // 所有行高固定，字母跳转才能算出确定偏移。
  static const double _headerHeight = 76;
  static const double _sectionHeight = 36;
  static const double _itemHeight = 78; // 卡片 68 + 行间 10
  static const double _footerHeight = 72;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final List<Contact> all = state.contacts;
    final List<Contact> archived =
        all.where((Contact c) => c.isArchived).toList();
    final List<Contact> pinned =
        all.where((Contact c) => !c.isArchived && c.pinned).toList();
    final Map<String, List<Contact>> grouped = <String, List<Contact>>{};
    for (final Contact c in all) {
      if (c.isArchived || c.pinned) continue;
      grouped.putIfAbsent(contactInitial(c.alias), () => <Contact>[]).add(c);
    }
    for (final List<Contact> list in grouped.values) {
      list.sort((Contact a, Contact b) => compareContactNames(a.alias, b.alias));
    }
    pinned.sort((Contact a, Contact b) => compareContactNames(a.alias, b.alias));
    archived.sort((Contact a, Contact b) => compareContactNames(a.alias, b.alias));

    final List<_Section> sections = <_Section>[
      if (pinned.isNotEmpty)
        _Section(kPinnedLetter, '置顶', pinned),
      for (final String letter in kContactIndexLetters)
        if (grouped.containsKey(letter))
          _Section(letter, letter == '#' ? '其他' : letter, grouped[letter]!),
    ];

    final Map<String, double> offsets = <String, double>{};
    double offset = _headerHeight;
    for (final _Section section in sections) {
      offsets[section.letter] = offset;
      offset += _sectionHeight + section.contacts.length * _itemHeight;
    }
    if (archived.isNotEmpty) {
      offset += _sectionHeight +
          (_archivedExpanded ? archived.length * _itemHeight : 0);
    }
    offset += _footerHeight;

    final int online = all
        .where((Contact c) => deviceForContact(state, c.id) != null)
        .length;

    return Stack(
      children: <Widget>[
        CustomScrollView(
          controller: _scroll,
          physics: const BouncingScrollPhysics(),
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: SizedBox(
                height: _headerHeight,
                child: WispPanelHeader(
                  title: '联系人',
                  subtitle: all.isEmpty
                      ? '互传过的设备都会记在这里'
                      : '${all.length} 位联系人 · $online 台在线',
                  compact: true,
                  padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
                ),
              ),
            ),
            if (all.isEmpty)
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
              for (final _Section section in sections)
                ..._sectionSlivers(context, state, section),
              if (archived.isNotEmpty)
                ..._archivedSlivers(context, state, archived),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: _footerHeight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 32, 20),
                    child: Text(
                      '按名称拼音首字母排序，点右侧字母可快速跳转；\n'
                      '归档只收起列表，聊天记录一条不删。',
                      style: TextStyle(
                        fontSize: 12,
                        color: WispColors.secondaryText(context),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        if (all.isNotEmpty)
          Positioned(
            right: 2,
            top: 0,
            bottom: 0,
            child: Center(
              child: _ContactIndexBar(
                available: offsets.keys.toSet(),
                onPick: (String letter) => _jumpTo(offsets, letter),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _sectionSlivers(
      BuildContext context, AppState state, _Section section) {
    return <Widget>[
      SliverToBoxAdapter(
        child: SizedBox(
          height: _sectionHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 32, 4),
            child: Row(
              children: <Widget>[
                Text(
                  section.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: WispColors.accent(context),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(height: 1, color: WispColors.line(context)),
                ),
                const SizedBox(width: 8),
                Text(
                  '${section.contacts.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: WispColors.secondaryText(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      SliverFixedExtentList(
        itemExtent: _itemHeight,
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 32, 10),
            child: _ContactCard(
              contact: section.contacts[index],
              state: state,
            ),
          ),
          childCount: section.contacts.length,
        ),
      ),
    ];
  }

  List<Widget> _archivedSlivers(
      BuildContext context, AppState state, List<Contact> archived) {
    return <Widget>[
      SliverToBoxAdapter(
        child: SizedBox(
          height: _sectionHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 32, 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _archivedExpanded = !_archivedExpanded),
              child: Row(
                children: <Widget>[
                  Text(
                    '已归档',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: WispColors.secondaryText(context),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${archived.length}',
                    style: TextStyle(
                      fontSize: 11,
                      color: WispColors.secondaryText(context),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _archivedExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: WispColors.secondaryText(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      if (_archivedExpanded)
        SliverFixedExtentList(
          itemExtent: _itemHeight,
          delegate: SliverChildBuilderDelegate(
            (BuildContext context, int index) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 32, 10),
              child: _ContactCard(contact: archived[index], state: state),
            ),
            childCount: archived.length,
          ),
        ),
    ];
  }

  void _jumpTo(Map<String, double> offsets, String letter) {
    if (!_scroll.hasClients || offsets.isEmpty) return;
    double? target = offsets[letter];
    // 点了一个没有联系人的字母：跳到它后面最近的一组，而不是毫无反应。
    if (target == null) {
      final List<String> keys = <String>[kPinnedLetter, ...kContactIndexLetters];
      final int from = keys.indexOf(letter);
      for (int i = from + 1; i < keys.length; i++) {
        if (offsets.containsKey(keys[i])) {
          target = offsets[keys[i]];
          break;
        }
      }
    }
    if (target == null) return;
    final double max = _scroll.position.maxScrollExtent;
    _scroll.animateTo(
      target.clamp(0.0, max > 0 ? max : target),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }
}

class _Section {
  const _Section(this.letter, this.label, this.contacts);

  final String letter;
  final String label;
  final List<Contact> contacts;
}

/// 右侧 A–Z 竖排索引：有联系人的字母高亮可点，空字母灰色但点了会跳到
/// 后面最近的一组（通讯录的统一习惯）。
class _ContactIndexBar extends StatelessWidget {
  const _ContactIndexBar({required this.available, required this.onPick});

  final Set<String> available;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final List<String> letters = <String>[
      kPinnedLetter,
      ...kContactIndexLetters,
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double height =
            (constraints.maxHeight - 24).clamp(180.0, 504.0).toDouble();
        // 每项高度留 2px 余量：28 项 × 精确均分再乘回去会多出 1~2px，
        // Column 直接溢出（widget 测试里会当成布局错误）。
        final double item = (height - 2) / letters.length;
        return Container(
          width: 24,
          height: height,
          decoration: BoxDecoration(
            color: WispColors.surface(context).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: WispColors.line(context)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              for (final String letter in letters)
                SizedBox(
                  height: item,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onPick(letter),
                    child: Center(
                      child: Text(
                        letter,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: available.contains(letter)
                              ? WispColors.accent(context)
                              : WispColors.secondaryText(context)
                                  .withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({required this.contact, required this.state});

  final Contact contact;
  final AppState state;

  /// 从联系人卡打开会话。在线设备用它的实时信息建会话；离线联系人用簿里
  /// 留存的身份建会话（历史还能看，聊天页会把输入框置灰）。两条路都必须
  /// 发 requestOpenConversation，否则外壳不切回「会话」页，点了像没反应。
  void _openConversation(AppState state) {
    if (state.conversationOf(contact.id) == null) {
      final WispDevice? device = deviceForContact(state, contact.id);
      if (device != null) {
        state.openChat(device);
      } else {
        state.openChatForContact(contact);
      }
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

    return SizedBox(
      height: 68,
      child: Material(
        color: WispColors.surface(context),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: () => _openConversation(state),
          onLongPress: () => _actions(context),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                    mainAxisAlignment: MainAxisAlignment.center,
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
