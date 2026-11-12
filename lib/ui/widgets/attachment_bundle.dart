import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/design/app_colors.dart';
import '../../core/utils/format.dart';
import '../../models/message.dart';

/// 一条消息里的附件区：单张图片直接预览，≥2 个文件折叠成一张卡。
///
/// 展开状态**不在这里**：由 `_ChatPageState` 按 entryId 存在 `Set<String>` 里，
/// 只由点击增删。这样新消息、滚动、rebuild 都不会把用户手动展开的卡收回去；
/// 切换会话或退出重进时那个 Set 被清空/重建，就回到默认折叠。
class AttachmentBundle extends StatelessWidget {
  const AttachmentBundle({
    super.key,
    required this.attachments,
    required this.expanded,
    required this.onToggle,
    required this.outgoing,
  });

  final List<ChatAttachment> attachments;
  final bool expanded;
  final VoidCallback onToggle;
  final bool outgoing;

  static const int foldThreshold = 2;

  bool get _foldable => attachments.length >= foldThreshold;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    if (!_foldable) return _single(context, attachments.first);
    return _bundle(context);
  }

  Widget _single(BuildContext context, ChatAttachment attachment) {
    final bool image = attachment.isImage && _exists(attachment);
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: WispColors.surface(context),
        border: Border.all(color: WispColors.line(context)),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (image)
            GestureDetector(
              onTap: () => _preview(context, attachment),
              child: Image.file(
                File(attachment.path),
                height: 180,
                width: 320,
                cacheWidth: 512,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _largePlaceholder(context, attachment),
              ),
            )
          else
            _largePlaceholder(context, attachment),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    attachment.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  Format.bytes(attachment.size),
                  style: TextStyle(
                    fontSize: 11,
                    color: WispColors.secondaryText(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bundle(BuildContext context) {
    final int total = attachments.fold(0, (int sum, ChatAttachment a) => sum + a.size);
    return Container(
      constraints: const BoxConstraints(maxWidth: 380),
      decoration: BoxDecoration(
        color: WispColors.surface(context),
        border: Border.all(color: WispColors.line(context)),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (!expanded)
            Row(
              children: <Widget>[
                ...attachments.take(2).map((ChatAttachment a) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _thumb(context, a, size: 42),
                    )),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '共 ${attachments.length} 个文件',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '合计 ${Format.bytes(total)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: WispColors.secondaryText(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            )
          else
            ...attachments.map((ChatAttachment a) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: <Widget>[
                      _thumb(context, a, size: 38),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          a.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        Format.bytes(a.size),
                        style: TextStyle(
                          fontSize: 11,
                          color: WispColors.secondaryText(context),
                        ),
                      ),
                    ],
                  ),
                )),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  expanded ? '手动展开后保持，不会被新消息收起' : '已折叠 · 进入会话默认状态',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: WispColors.secondaryText(context).withValues(alpha: 0.8),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onToggle,
                icon: Icon(expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 16),
                label: Text(expanded ? '收起' : '展开 ${attachments.length} 项',
                    style: const TextStyle(fontSize: 11.5)),
                style: TextButton.styleFrom(
                  foregroundColor: WispColors.accent(context),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _exists(ChatAttachment attachment) =>
      attachment.hasPath && File(attachment.path).existsSync();

  Widget _thumb(BuildContext context, ChatAttachment attachment, {double size = 42}) {
    final bool image = attachment.isImage && _exists(attachment);
    return GestureDetector(
      onTap: image ? () => _preview(context, attachment) : null,
      child: Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: WispColors.surfaceAlt(context),
          borderRadius: BorderRadius.circular(9),
        ),
        child: image
            ? Image.file(
                File(attachment.path),
                width: size,
                height: size,
                cacheWidth: 256,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _placeholder(context, attachment, size),
              )
            : _placeholder(context, attachment, size),
      ),
    );
  }

  Widget _placeholder(BuildContext context, ChatAttachment attachment, double size) {
    return Icon(
      attachment.isImage ? Icons.image_outlined : Icons.insert_drive_file_rounded,
      size: size * 0.45,
      color: WispColors.secondaryText(context).withValues(alpha: 0.7),
    );
  }

  Widget _largePlaceholder(BuildContext context, ChatAttachment attachment) {
    return Container(
      height: 108,
      color: WispColors.surfaceAlt(context),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            attachment.isImage ? Icons.broken_image_outlined : Icons.insert_drive_file_rounded,
            size: 30,
            color: WispColors.secondaryText(context).withValues(alpha: 0.65),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              attachment.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  void _preview(BuildContext context, ChatAttachment attachment) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: GestureDetector(
          onTap: () => Navigator.of(dialogContext).pop(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(
              File(attachment.path),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Container(
                padding: const EdgeInsets.all(24),
                color: WispColors.surface(dialogContext),
                child: const Text('这张图片已经不在原来的位置了'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
