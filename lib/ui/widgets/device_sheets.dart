import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../models/device.dart';
import '../../state/app_state.dart';
import '../flows/send_flow.dart';
import 'device_tile.dart';
import 'gradient_button.dart';

/// 手动输入 IP 连接（原「附近」页能力，现挂在设备选择器 / 联系人流程里）。
Future<void> showManualConnect(BuildContext context, AppState state) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 480),
    builder: (BuildContext context) => ManualConnectSheet(state: state),
  );
}

class ManualConnectSheet extends StatefulWidget {
  const ManualConnectSheet({super.key, required this.state});

  final AppState state;

  @override
  State<ManualConnectSheet> createState() => _ManualConnectSheetState();
}

class _ManualConnectSheetState extends State<ManualConnectSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final String? error = await widget.state.connectManually(_controller.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == null) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        top: 4,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('手动连接', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 6),
          Text(
            '组播被路由器隔离时，直接输入对方 IP 更可靠。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    hintText: '192.168.1.24',
                    filled: true,
                    fillColor: WispColors.surfaceAlt(context),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 10),
              GradientButton(
                label: _busy ? '连接中' : '连接',
                loading: _busy,
                expand: false,
                height: 54,
                onPressed: _submit,
              ),
            ],
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(color: WispColors.danger, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}

/// 设备详情：一个动作明确的面板，不做二级跳转。
Future<void> showDeviceSheet(BuildContext context, AppState state, WispDevice device) {
  return showModalBottomSheet<void>(
    context: context,
    constraints: const BoxConstraints(maxWidth: 480),
    builder: (BuildContext sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          DeviceAvatar(kind: device.kind, size: 58),
          const SizedBox(height: 12),
          Text(device.alias, style: Theme.of(sheetContext).textTheme.headlineMedium),
          const SizedBox(height: 4),
          Text(
            '${device.modelLabel} · ${device.ip}:${device.port}',
            style: Theme.of(sheetContext).textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: WispColors.surface(sheetContext),
              border: Border.all(color: WispColors.line(sheetContext)),
            ),
            child: Column(
              children: <Widget>[
                _DetailRow(label: '协议版本', value: device.version),
                const SizedBox(height: 10),
                _DetailRow(label: '指纹', value: device.shortFingerprint),
                const SizedBox(height: 10),
                _DetailRow(label: '传输加密', value: device.https ? '已开启' : '未开启'),
              ],
            ),
          ),
          const SizedBox(height: 20),
          GradientButton(
            label: '发送文件',
            icon: Icons.arrow_upward_rounded,
            onPressed: () async {
              Navigator.of(sheetContext).pop();
              await startSendFlow(context, state, device);
            },
          ),
        ],
      ),
    ),
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const Spacer(),
        Text(value, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

/// 在线状态点 + 文案的小徽标，联系人页与选择器共用。
class PresenceDot extends StatelessWidget {
  const PresenceDot({super.key, required this.online, this.label});

  final bool online;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final Color color = online ? WispColors.success : WispColors.secondaryText(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        if (label != null) ...<Widget>[
          const SizedBox(width: 5),
          Text(
            label!,
            style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );
  }
}

/// 从 AppState 的设备表里找一台联系人对应的在线设备（按 fingerprint）。
WispDevice? deviceForContact(AppState state, String fingerprint) {
  final String key = fingerprint.trim();
  if (key.isEmpty) return null;
  try {
    return state.devices.firstWhere((WispDevice d) => d.fingerprint.trim() == key);
  } on StateError {
    return null;
  }
}

/// Provider 快捷读取，供静态弹层里少写一遍 watch。
AppState stateOf(BuildContext context) => context.read<AppState>();
