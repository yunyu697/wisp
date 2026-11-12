import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/utils/format.dart';
import '../../models/contact.dart';
import '../../models/device.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import 'device_tile.dart';

/// 三栏主场的右栏：这台设备「是谁」，以及和它有关的状态与开关。
///
/// 身份只认 fingerprint；ip / 别名 / 在线状态都只是可变属性。对方重装或
/// 重置证书后 fingerprint 会变，这里**不自动合并**，避免把 A 的文件挂到 B 名下。
class ContactInspector extends StatelessWidget {
  const ContactInspector({super.key, required this.peerKey});

  final String peerKey;

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final Conversation? conversation = state.conversationOf(peerKey);
    final Contact? contact = state.contactOf(peerKey);
    final WispDevice? device = _device(state, conversation);

    final String alias = contact?.alias ?? conversation?.peerAlias ?? '未知设备';
    final String fingerprint = contact?.id ?? device?.fingerprint ?? '';
    final bool hasIdentity = fingerprint.trim().isNotEmpty;
    final bool trusted = hasIdentity &&
        state.settings.trustedFingerprints.contains(fingerprint);
    final bool online = device != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _card(
            context,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    DeviceAvatar(kind: contact?.kind ?? device?.kind ?? DeviceKind.unknown, size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(alias,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 2),
                          Text(
                            online ? '在线 · 可直达' : '离线 · 记录仍在这里',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _kv(context, '稳定标识', hasIdentity ? _short(fingerprint) : '无身份'),
                _kv(context, '当前地址', device?.ip ?? conversation?.peerIp ?? '—'),
                _kv(context, '曾用网络', '${contact?.knownIps.length ?? 0} 个'),
                _kv(context, '首次交互',
                    contact == null ? '—' : Format.dayLabel(contact.firstSeen)),
                _kv(context, '会话状态', contact?.stateLabel ?? '临时会话'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '换 Wi-Fi、换网段都还是同一台设备。对方重装或重置证书后标识会变，不会自动合并。',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: WispColors.secondaryText(context),
            ),
          ),
          if (contact != null && contact.isTemporary) ...<Widget>[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => state.keepContact(contact.id),
              icon: const Icon(Icons.person_add_alt_rounded, size: 16),
              label: const Text('保留为联系人', style: TextStyle(fontSize: 12.5)),
              style: OutlinedButton.styleFrom(
                foregroundColor: WispColors.accent(context),
                side: BorderSide(color: WispColors.line(context)),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _card(
            context,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text('免确认接收',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 3),
                      Text(
                        hasIdentity
                            ? (trusted ? '已加入白名单 · 按稳定标识' : '这台设备发来的文件仍需你同意')
                            : '老版本或匿名设备不能被加入白名单',
                        style: TextStyle(
                          fontSize: 11,
                          color: WispColors.secondaryText(context),
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: trusted,
                  onChanged: hasIdentity
                      ? (bool _) => state.toggleTrusted(fingerprint)
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _shared(context, conversation),
        ],
      ),
    );
  }

  Widget _shared(BuildContext context, Conversation? conversation) {
    final List<ChatMessage> messages = conversation?.messages ?? <ChatMessage>[];
    int texts = 0;
    int images = 0;
    int files = 0;
    final List<ChatAttachment> previews = <ChatAttachment>[];
    for (final ChatMessage message in messages) {
      if (message.hasAttachments) {
        for (final ChatAttachment attachment in message.attachments) {
          if (attachment.isImage) {
            images += 1;
            if (attachment.hasPath && previews.length < 4) previews.add(attachment);
          } else {
            files += 1;
          }
        }
      } else if (message.text.trim().isNotEmpty) {
        texts += 1;
      }
    }
    return _card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('共享内容',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Text(
            '全部 ${messages.length} · 图片 $images · 文件 $files · 文字 $texts',
            style: TextStyle(
                fontSize: 11, color: WispColors.secondaryText(context)),
          ),
          if (previews.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                for (final ChatAttachment attachment in previews)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Container(
                      width: 42,
                      height: 42,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: WispColors.surfaceAlt(context),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: File(attachment.path).existsSync()
                          ? Image.file(File(attachment.path),
                              cacheWidth: 128,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Icon(
                                    Icons.image_outlined,
                                    size: 18,
                                    color: WispColors.secondaryText(context),
                                  ))
                          : Icon(Icons.image_outlined,
                              size: 18,
                              color: WispColors.secondaryText(context)),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _card(BuildContext context, {required Widget child}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: WispColors.surface(context),
          border: Border.all(color: WispColors.line(context)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: child,
      );

  Widget _kv(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: <Widget>[
            Text(label,
                style: TextStyle(
                    fontSize: 11.5, color: WispColors.secondaryText(context))),
            const Spacer(),
            Text(value,
                style: const TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w500)),
          ],
        ),
      );

  String _short(String id) =>
      id.length <= 8 ? id.toUpperCase() : '${id.substring(0, 8).toUpperCase()}…';

  WispDevice? _device(AppState state, Conversation? conversation) {
    for (final WispDevice device in state.devices) {
      if (device.key == peerKey) return device;
    }
    if (conversation == null) return null;
    for (final WispDevice device in state.devices) {
      if (device.ip == conversation.peerIp) return device;
    }
    return null;
  }
}
