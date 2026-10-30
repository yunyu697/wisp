import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/design/app_motion.dart';
import '../../core/utils/format.dart';
import '../../models/transfer.dart';
import '../../state/app_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/wisp_card.dart';

/// 记录页：按天分组，一眼能看出"什么时候、跟谁、传了多少"。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final List<TransferRecord> records = state.history;
    final List<Object> items = _buildItems(records);

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
                      Text('记录', style: Theme.of(context).textTheme.displayLarge),
                      const SizedBox(height: 4),
                      Text(
                        records.isEmpty ? '还没有传输记录' : '共 ${records.length} 次传输',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (records.isNotEmpty)
                  TextButton(
                    onPressed: () => _confirmClear(context, state),
                    style: TextButton.styleFrom(
                      foregroundColor: WispColors.secondaryText(context),
                    ),
                    child: const Text('清空', style: TextStyle(fontSize: 14)),
                  ),
              ],
            ),
          ),
        ),
        if (records.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.history_rounded,
              title: '传输完成后会留在这里',
              subtitle: '记录只存在本机，随时可以清空。',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
            sliver: SliverList.builder(
              itemCount: items.length,
              itemBuilder: (BuildContext context, int index) {
                final Object item = items[index];
                if (item is String) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
                    child: Text(
                      item,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  );
                }
                final TransferRecord record = item as TransferRecord;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: StaggeredItem(
                    index: index,
                    child: Dismissible(
                      key: ValueKey<String>(record.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 22),
                        decoration: BoxDecoration(
                          color: WispColors.danger.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(Icons.delete_outline_rounded, color: WispColors.danger),
                      ),
                      onDismissed: (_) => state.removeHistory(record.id),
                      child: _HistoryTile(
                        record: record,
                        onActions: () => _openActions(context, state, record),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  /// 把记录摊平成"日期标题 + 条目"的混合列表。
  List<Object> _buildItems(List<TransferRecord> records) {
    final List<Object> items = <Object>[];
    String? currentDay;
    for (final TransferRecord record in records) {
      final String day = Format.dayLabel(record.time);
      if (day != currentDay) {
        currentDay = day;
        items.add(day);
      }
      items.add(record);
    }
    return items;
  }

  /// 单条记录的操作面板：再次发送 / 打开所在目录 / 删除。
  /// 用底部面板而不是长按菜单——桌面和触屏都能用，且能写清楚"为什么不可用"。
  void _openActions(BuildContext context, AppState state, TransferRecord record) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: WispColors.surface(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: WispColors.line(sheetContext),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        record.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(sheetContext).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
              ),
              _ActionRow(
                icon: Icons.send_rounded,
                label: '再次发送',
                hint: record.canResend
                    ? '把源文件放回待发清单'
                    : (record.direction == TransferDirection.outgoing
                        ? '源文件已不在原来的位置'
                        : '接收记录没有源文件'),
                enabled: record.canResend,
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final String? error = await state.resendFromRecord(record);
                  if (error != null && context.mounted) {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(content: Text(error)));
                  }
                },
              ),
              _ActionRow(
                icon: Icons.folder_open_rounded,
                label: '打开所在目录',
                hint: record.direction == TransferDirection.outgoing ? '源文件所在目录' : '接收保存的目录',
                enabled: true,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  state.openRecordFolder(record);
                },
              ),
              _ActionRow(
                icon: Icons.delete_outline_rounded,
                label: '删除这条记录',
                hint: '只删记录，不动文件',
                enabled: true,
                danger: true,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  state.removeHistory(record.id);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmClear(BuildContext context, AppState state) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: WispColors.surface(dialogContext),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('清空记录'),
        content: const Text('只删除本机的历史记录，不影响已经传过去的文件。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              state.clearHistory();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('清空', style: TextStyle(color: WispColors.danger)),
          ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.record, required this.onActions});

  final TransferRecord record;
  final VoidCallback onActions;

  @override
  Widget build(BuildContext context) {
    final bool outgoing = record.direction == TransferDirection.outgoing;
    final Color tint = outgoing ? WispColors.teal : WispColors.success;
    return WispCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      radius: 20,
      onTap: onActions,
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              outgoing ? Icons.north_east_rounded : Icons.south_west_rounded,
              size: 18,
              color: tint,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  record.summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 3),
                Text(
                  '${outgoing ? "发送给" : "接收自"} ${record.peerAlias} · ${Format.bytes(record.bytes)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(Format.clock(record.time), style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 3),
              AnimatedOpacity(
                opacity: 1,
                duration: WispMotion.fast,
                child: Text(
                  record.success ? '完成' : '中断',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: record.success ? WispColors.success : WispColors.warning,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 2),
          // 轻量提示"这张卡能点"，具体操作在底部面板里。
          Icon(
            Icons.more_horiz_rounded,
            size: 18,
            color: WispColors.secondaryText(context).withValues(alpha: 0.55),
          ),
        ],
      ),
    );
  }
}

/// 底部面板里的一行操作：图标 + 标题 + 说明，不可用时整行变灰并给出原因。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.hint,
    required this.enabled,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final String hint;
  final bool enabled;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color tint = danger ? WispColors.danger : WispColors.teal;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            child: Row(
              children: <Widget>[
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 18, color: tint),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(label, style: Theme.of(context).textTheme.bodyLarge),
                      const SizedBox(height: 2),
                      Text(hint, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
