import 'package:flutter/material.dart';

import '../../core/design/app_colors.dart';
import '../../core/utils/pickers.dart';
import '../../models/device.dart';
import '../../models/transfer.dart';
import '../../state/app_state.dart';
import '../pages/transfer_page.dart';

/// 发送流程的唯一入口。
///
/// 顺序：缺文件就选文件 → 发起传输 → 立刻进入传输页 → 失败再回到这里处理。
/// 先把界面切过去，用户不会盯着一个没反应的按钮。
Future<void> startSendFlow(
  BuildContext context,
  AppState state,
  WispDevice device, {
  bool pickIfEmpty = true,
}) async {
  if (state.draft.isEmpty) {
    if (!pickIfEmpty) return;
    final List<TransferFile> files = await Pickers.pickFiles();
    if (files.isEmpty) return;
    state.addFiles(files);
  }
  if (!context.mounted) return;
  await _dispatch(context, state, device);
}

Future<void> _dispatch(
  BuildContext context,
  AppState state,
  WispDevice device, {
  String? pin,
}) async {
  final Future<String?> pending = state.sendTo(device, pin: pin);
  final TransferSession? session = state.activeSession;

  if (session == null) {
    final String? error = await pending;
    if (error != null && context.mounted) _toast(context, error);
    return;
  }

  final NavigatorState navigator = Navigator.of(context);
  navigator.push(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 340),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (BuildContext _, Animation<double> __, Animation<double> ___) =>
          TransferPage(session: session),
      transitionsBuilder:
          (BuildContext _, Animation<double> animation, Animation<double> __, Widget child) {
        final Animation<double> curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero).animate(curved),
            child: child,
          ),
        );
      },
    ),
  );

  final String? error = await pending;
  if (error == null) return;

  // PIN 是唯一需要"打断"的错误：其余错误在传输页里就能看明白。
  if (error.contains('PIN')) {
    if (!context.mounted) return;
    final String? entered = await _askPin(context, device.alias);
    if (entered != null && context.mounted) {
      await _dispatch(context, state, device, pin: entered);
    }
    return;
  }
  if (context.mounted) _toast(context, error);
}

Future<String?> _askPin(BuildContext context, String alias) {
  final TextEditingController controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      backgroundColor: WispColors.surface(dialogContext),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text('需要 PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$alias 开启了 PIN 保护，请输入对方屏幕上显示的 6 位数字。',
            style: Theme.of(dialogContext).textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              counterText: '',
              filled: true,
              fillColor: WispColors.surfaceAlt(dialogContext),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
          child: const Text('确认'),
        ),
      ],
    ),
  );
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
