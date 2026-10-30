import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/design/app_motion.dart';
import '../../core/utils/format.dart';
import '../../models/transfer.dart';
import '../../state/app_state.dart';
import '../widgets/device_tile.dart';
import '../widgets/gradient_button.dart';
import '../widgets/progress_ring.dart';
import '../widgets/wisp_card.dart';

/// 传输页：一个会话的完整视图。
///
/// 从"点击发送"到"完成"是一条不被打断的路径，
/// 所以这里用全屏路由而不是弹窗，避免误触关闭导致用户以为传输中止。
class TransferPage extends StatelessWidget {
  const TransferPage({super.key, required this.session});

  final TransferSession session;

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final bool finished = session.status.isFinished;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _TopBar(
              onClose: () => Navigator.of(context).maybePop(),
              status: session.status,
            ),
            Expanded(
              // 滚动视图仍铺满高度；只把内部内容居中限宽，
              // 避免横屏时环形/统计/文件列表被横向拉散（竖屏宽度不足 640，无影响）。
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Column(
                      children: <Widget>[
                        _PeerHeader(session: session),
                        const SizedBox(height: 26),
                        ProgressRing(
                          progress: session.progress,
                          size: 210,
                          strokeWidth: 13,
                          child: _RingContent(session: session),
                        ),
                        const SizedBox(height: 22),
                        _StatsRow(session: session),
                        const SizedBox(height: 26),
                        _FileList(session: session),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: finished
                      ? GradientButton(
                          label: session.status == TransferStatus.completed ? '完成' : '返回',
                          onPressed: () => Navigator.of(context).maybePop(),
                        )
                      : GhostButton(
                          label: '取消传输',
                          icon: Icons.close_rounded,
                          expand: true,
                          onPressed: () async {
                            await state.cancelSession(session);
                            if (context.mounted) Navigator.of(context).maybePop();
                          },
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onClose, required this.status});

  final VoidCallback onClose;
  final TransferStatus status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 16, 6),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 26),
          ),
          const Spacer(),
          AnimatedSwitcher(
            duration: WispMotion.fast,
            child: Text(
              status.label,
              key: ValueKey<String>(status.label),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: WispColors.secondaryText(context),
                  ),
            ),
          ),
          const Spacer(),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}

class _PeerHeader extends StatelessWidget {
  const _PeerHeader({required this.session});

  final TransferSession session;

  @override
  Widget build(BuildContext context) {
    final bool outgoing = session.direction == TransferDirection.outgoing;
    return Column(
      children: <Widget>[
        DeviceAvatar(kind: session.peerKind, size: 54),
        const SizedBox(height: 10),
        Text(session.peerAlias, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(
          outgoing ? '正在发送到 ${session.peerIp}' : '来自 ${session.peerIp}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _RingContent extends StatelessWidget {
  const _RingContent({required this.session});

  final TransferSession session;

  @override
  Widget build(BuildContext context) {
    final bool done = session.status == TransferStatus.completed;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedSwitcher(
          duration: WispMotion.base,
          child: Icon(
            done ? Icons.check_rounded : Icons.arrow_upward_rounded,
            key: ValueKey<bool>(done),
            size: 26,
            color: done ? WispColors.success : WispColors.accent(context),
          ),
        ),
        const SizedBox(height: 6),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: session.progress),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (BuildContext context, double v, Widget? _) => Text(
            '${(v * 100).round()}%',
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          done ? '已送达' : Format.speed(session.bytesPerSecond),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.session});

  final TransferSession session;

  @override
  Widget build(BuildContext context) {
    final Duration? remaining = session.remaining;
    return Row(
      children: <Widget>[
        Expanded(
          child: _Stat(
            label: '已传输',
            value: '${Format.bytes(session.doneBytes)} / ${Format.bytes(session.totalBytes)}',
          ),
        ),
        Container(width: 1, height: 30, color: WispColors.line(context)),
        Expanded(
          child: _Stat(
            label: '剩余时间',
            value: session.status == TransferStatus.completed
                ? '—'
                : (remaining == null ? '估算中' : Format.duration(remaining)),
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(value, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 3),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({required this.session});

  final TransferSession session;

  @override
  Widget build(BuildContext context) {
    return WispCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < session.files.length; i++) ...<Widget>[
            _FileRow(file: session.files[i]),
            if (i != session.files.length - 1)
              Divider(height: 1, color: WispColors.line(context)),
          ],
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file});

  final TransferFile file;

  @override
  Widget build(BuildContext context) {
    final Color tint = FileKind.colorFor(file.name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(FileKind.iconFor(file.name), size: 18, color: tint),
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
                const SizedBox(height: 6),
                SlimProgress(value: file.progress),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            Format.bytes(file.size),
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
  }
}
