import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/design/app_motion.dart';
import '../../core/utils/format.dart';
import '../../core/utils/pickers.dart';
import '../../models/device.dart';
import '../../models/transfer.dart';
import '../../state/app_state.dart';
import '../flows/send_flow.dart';
import '../responsive.dart';
import '../widgets/device_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_button.dart';
import '../widgets/wisp_card.dart';

/// 发送页：左边是"要发什么"，右边是"发给谁"，底部只有一个动作。
class SendPage extends StatefulWidget {
  const SendPage({super.key});

  @override
  State<SendPage> createState() => _SendPageState();
}

class _SendPageState extends State<SendPage> {
  String? _targetKey;
  bool _picking = false;

  /// 历史里"再次发送"会把对端 IP 放进 state：对方还在线就顺手选中，
  /// 不在线就什么都不做，让用户自己挑。消费一次即清空，避免影响后续操作。
  void _applyPreferredPeer(AppState state) {
    final String? ip = state.preferredPeerIp;
    if (ip == null) return;
    state.preferredPeerIp = null;
    final WispDevice? match = state.devices
        .cast<WispDevice?>()
        .firstWhere((WispDevice? d) => d?.ip == ip, orElse: () => null);
    if (match == null || match.key == _targetKey) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _targetKey = match.key);
    });
  }

  Future<void> _pick(Future<List<TransferFile>> Function() task, AppState state) async {
    setState(() => _picking = true);
    try {
      final List<TransferFile> files = await task();
      if (files.isNotEmpty) state.addFiles(files);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _pickText(AppState state) async {
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => _TextSheet(),
    );
    if (text == null || text.trim().isEmpty) return;
    final TransferFile? file = await Pickers.textToFile(text);
    if (file != null) state.addFiles(<TransferFile>[file]);
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final List<WispDevice> devices = state.devices;
    _applyPreferredPeer(state);
    final WispDevice? target = devices.cast<WispDevice?>().firstWhere(
          (WispDevice? d) => d?.key == _targetKey,
          orElse: () => devices.isEmpty ? null : devices.first,
        );

    // 横屏：左「发什么」右「发给谁」，两栏并排，避免选择面板被拉成超宽横幅。
    if (isWideLayout(context)) {
      return _wide(context, state, devices, target);
    }
    return _narrow(context, state, devices, target);
  }

  Widget _header(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('发送', style: Theme.of(context).textTheme.displayLarge),
          const SizedBox(height: 4),
          Text(
            state.draft.isEmpty
                ? '选文件、文件夹，或者直接发一段文字'
                : '${state.draft.length} 个文件 · ${Format.bytes(state.draftBytes)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// 编辑区：空态是添加面板，有草稿则是文件列表。竖屏/横屏共用。
  Widget _compose(BuildContext context, AppState state) {
    return AnimatedSwitcher(
      duration: WispMotion.base,
      switchInCurve: WispMotion.enter,
      child: state.draft.isEmpty
          ? _PickerPanel(
              key: const ValueKey<String>('picker'),
              busy: _picking,
              onFiles: () => _pick(Pickers.pickFiles, state),
              onFolder: () => _pick(Pickers.pickFolder, state),
              onText: () => _pickText(state),
            )
          : _DraftList(
              key: const ValueKey<String>('draft'),
              state: state,
              onAdd: () => _pick(Pickers.pickFiles, state),
            ),
    );
  }

  Widget _sendButton(BuildContext context, AppState state, WispDevice? target) {
    return GradientButton(
      label: target == null ? '附近没有可用设备' : '发送到 ${target.alias}',
      icon: Icons.arrow_upward_rounded,
      onPressed: target == null || state.draft.isEmpty
          ? null
          : () => startSendFlow(context, state, target, pickIfEmpty: false),
    );
  }

  Widget _narrow(
    BuildContext context,
    AppState state,
    List<WispDevice> devices,
    WispDevice? target,
  ) {
    return Column(
      children: <Widget>[
        Expanded(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: <Widget>[
              SliverToBoxAdapter(child: _header(context, state)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: _compose(context, state),
                ),
              ),
              if (state.draft.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: SectionHeader(
                      title: '发送到',
                      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                      trailing: devices.isEmpty
                          ? null
                          : Text('${devices.length} 台在线', style: Theme.of(context).textTheme.labelMedium),
                    ),
                  ),
                ),
              if (state.draft.isNotEmpty)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 92,
                    child: devices.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Text(
                              '附近还没有设备。先回到「附近」页，确认双方在同一个 Wi-Fi。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          )
                        : ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            itemCount: devices.length,
                            separatorBuilder: (_, __) => const SizedBox(width: 10),
                            itemBuilder: (BuildContext context, int index) {
                              final WispDevice device = devices[index];
                              final bool selected = device.key == target?.key;
                              return _TargetChip(
                                device: device,
                                selected: selected,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  setState(() => _targetKey = device.key);
                                },
                              );
                            },
                          ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: _sendButton(context, state, target),
        ),
      ],
    );
  }

  Widget _wide(
    BuildContext context,
    AppState state,
    List<WispDevice> devices,
    WispDevice? target,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          flex: 3,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: <Widget>[
              SliverToBoxAdapter(child: _header(context, state)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: _compose(context, state),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
        VerticalDivider(width: 1, thickness: 1, color: WispColors.line(context)),
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: <Widget>[
                    Text(
                      '发送到',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const Spacer(),
                    if (devices.isNotEmpty)
                      Text('${devices.length} 台在线', style: Theme.of(context).textTheme.labelMedium),
                  ],
                ),
              ),
              Expanded(
                child: devices.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          '附近还没有设备。先回到「附近」页，确认双方在同一个 Wi-Fi。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                        itemCount: devices.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (BuildContext context, int index) {
                          final WispDevice device = devices[index];
                          return _TargetRow(
                            device: device,
                            selected: device.key == target?.key,
                            onTap: () {
                              HapticFeedback.selectionClick();
                              setState(() => _targetKey = device.key);
                            },
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: _sendButton(context, state, target),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PickerPanel extends StatelessWidget {
  const _PickerPanel({
    super.key,
    required this.busy,
    required this.onFiles,
    required this.onFolder,
    required this.onText,
  });

  final bool busy;
  final VoidCallback onFiles;
  final VoidCallback onFolder;
  final VoidCallback onText;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        color: WispColors.surface(context),
        border: Border.all(color: WispColors.line(context)),
      ),
      child: Column(
        children: <Widget>[
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: WispColors.softGradient,
              boxShadow: <BoxShadow>[
                BoxShadow(color: WispColors.teal.withValues(alpha: 0.28), blurRadius: 20, offset: const Offset(0, 8)),
              ],
            ),
            child: const Icon(Icons.add_rounded, color: Colors.white, size: 30),
          ),
          const SizedBox(height: 16),
          Text('添加要发送的内容', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '支持拖拽 · 文件只在两台设备之间流动',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              Expanded(
                child: _PickAction(
                  icon: Icons.insert_drive_file_rounded,
                  label: '文件',
                  onTap: busy ? null : onFiles,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _PickAction(
                  icon: Icons.folder_rounded,
                  label: '文件夹',
                  onTap: busy ? null : onFolder,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _PickAction(
                  icon: Icons.notes_rounded,
                  label: '文字',
                  onTap: busy ? null : onText,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PickAction extends StatelessWidget {
  const _PickAction({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WispColors.surfaceAlt(context),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: <Widget>[
              Icon(icon, size: 21, color: WispColors.accent(context)),
              const SizedBox(height: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: WispColors.secondaryText(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DraftList extends StatelessWidget {
  const _DraftList({super.key, required this.state, required this.onAdd});

  final AppState state;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final List<TransferFile> files = state.draft;
    return WispCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < files.length; i++)
            StaggeredItem(
              index: i,
              child: _DraftRow(
                file: files[i],
                onRemove: () => state.removeFile(files[i]),
              ),
            ),
          Divider(height: 1, color: WispColors.line(context)),
          InkWell(
            onTap: onAdd,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(Icons.add_rounded, size: 18, color: WispColors.accent(context)),
                  const SizedBox(width: 6),
                  Text(
                    '继续添加',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: WispColors.accent(context),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: state.clearDraft,
                    style: TextButton.styleFrom(
                      foregroundColor: WispColors.secondaryText(context),
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('清空', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DraftRow extends StatelessWidget {
  const _DraftRow({required this.file, required this.onRemove});

  final TransferFile file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final Color tint = FileKind.colorFor(file.name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(FileKind.iconFor(file.name), size: 19, color: tint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 2),
                Text(Format.bytes(file.size), style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
          ),
          IconButton(
            onPressed: onRemove,
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            color: WispColors.secondaryText(context),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _TargetChip extends StatelessWidget {
  const _TargetChip({required this.device, required this.selected, required this.onTap});

  final WispDevice device;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color accent = WispColors.accent(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: WispMotion.base,
        curve: WispMotion.enter,
        width: 112,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: selected ? accent.withValues(alpha: 0.10) : WispColors.surface(context),
          border: Border.all(
            color: selected ? accent.withValues(alpha: 0.55) : WispColors.line(context),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          children: <Widget>[
            AnimatedScale(
              scale: selected ? 1.0 : 0.92,
              duration: WispMotion.base,
              curve: WispMotion.emphasis,
              child: DeviceAvatar(kind: device.kind, size: 34),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                device.alias,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? accent : WispColors.secondaryText(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 横屏右栏的竖向目标行：比横向 chip 更适合放在侧边窄栏里。
class _TargetRow extends StatelessWidget {
  const _TargetRow({required this.device, required this.selected, required this.onTap});

  final WispDevice device;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color accent = WispColors.accent(context);
    return Material(
      color: selected ? accent.withValues(alpha: 0.10) : WispColors.surface(context),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? accent.withValues(alpha: 0.55) : WispColors.line(context),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            children: <Widget>[
              DeviceAvatar(kind: device.kind, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      device.alias,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        color: selected ? accent : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${device.modelLabel} · ${device.ip}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 20,
                color: selected ? accent : WispColors.secondaryText(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextSheet extends StatefulWidget {
  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: WispColors.surface(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text('发送文字'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 5,
        minLines: 3,
        decoration: InputDecoration(
          hintText: '粘贴链接或一段话…',
          filled: true,
          fillColor: WispColors.surfaceAlt(context),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('添加'),
        ),
      ],
    );
  }
}
