import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/design/app_colors.dart';
import '../../core/design/app_motion.dart';
import '../../models/device.dart';
import '../../state/app_state.dart';
import '../flows/send_flow.dart';
import '../responsive.dart';
import '../widgets/device_tile.dart';
import '../widgets/gradient_button.dart';
import '../widgets/identity_card.dart';
import '../widgets/radar_view.dart';
import '../widgets/wisp_card.dart';
import '../widgets/workspace.dart';

/// 附近页：左栏"我是谁 + 扫描状态"，右栏"附近有谁"。
///
/// 重做后与「消息」页同构：宽窗口走「工作台」（固定左栏 + 主面板），
/// 窄窗口回落到单栏，功能不变（发现、手动连接、一键发送）。
class NearbyPage extends StatelessWidget {
  const NearbyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    if (isWideLayout(context)) return _wide(context, state);
    return _narrow(context, state);
  }

  // ---------------------------------------------------------------- 宽窗口

  Widget _wide(BuildContext context, AppState state) {
    final List<WispDevice> devices = state.devices;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        WispAside(width: 324, child: _aside(context, state)),
        Expanded(child: _devicesPanel(context, state, devices)),
      ],
    );
  }

  Widget _aside(BuildContext context, AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        WispPanelHeader(
          title: '附近',
          subtitle: state.devices.isEmpty
              ? '同一网络下的设备会自动出现'
              : '发现 ${state.devices.length} 台设备',
          compact: true,
          trailing: _RoundAction(
            icon: Icons.refresh_rounded,
            tooltip: '重新扫描',
            onTap: () {
              HapticFeedback.selectionClick();
              state.rescan();
            },
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: <Widget>[
              IdentityCard(state: state),
              const SizedBox(height: 14),
              _scanCard(context, state),
              const SizedBox(height: 14),
              Text(
                state.settings.hasUsername
                    ? '只显示「${state.settings.username}」名下的设备。\n对方也要填同一个用户名才会出现。'
                    : '把两台设备连到同一个 Wi-Fi，\n就能直接互传，不经过任何服务器。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.6),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _devicesPanel(BuildContext context, AppState state, List<WispDevice> devices) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        WispPanelHeader(
          title: '附近的设备',
          subtitle: devices.isEmpty ? '等待被发现' : '${devices.length} 台可发送',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _RoundAction(
                icon: Icons.qr_code_scanner_rounded,
                tooltip: '手动连接',
                onTap: () => _showManualConnect(context, state),
              ),
              const SizedBox(width: 8),
              _RoundAction(
                icon: Icons.refresh_rounded,
                tooltip: '重新扫描',
                onTap: () {
                  HapticFeedback.selectionClick();
                  state.rescan();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: devices.isEmpty
              ? _emptyPanel(context, state)
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisExtent: 84,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: devices.length,
                  itemBuilder: (BuildContext context, int index) =>
                      _deviceCard(context, state, devices[index], index),
                ),
        ),
        _footer(context, state),
      ],
    );
  }

  Widget _emptyPanel(BuildContext context, AppState state) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const RadarView(size: 168),
            const SizedBox(height: 16),
            Text(
              '还没有发现设备',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              '同一 Wi-Fi 下的设备会自动出现；\n组播被隔离时，手动输入对方 IP。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.6),
            ),
            const SizedBox(height: 14),
            GhostButton(
              label: '手动输入 IP 连接',
              icon: Icons.link_rounded,
              onPressed: () => _showManualConnect(context, state),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 窄窗口

  Widget _narrow(BuildContext context, AppState state) {
    final List<WispDevice> devices = state.devices;
    return RefreshIndicator(
      color: WispColors.teal,
      onRefresh: state.rescan,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: WispPanelHeader(
              title: '附近',
              subtitle: devices.isEmpty ? '同一网络下的设备会自动出现' : '发现 ${devices.length} 台设备',
              compact: true,
              padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _RoundAction(
                    icon: Icons.qr_code_scanner_rounded,
                    tooltip: '手动连接',
                    onTap: () => _showManualConnect(context, state),
                  ),
                  const SizedBox(width: 8),
                  _RoundAction(
                    icon: Icons.refresh_rounded,
                    tooltip: '重新扫描',
                    onTap: () {
                      HapticFeedback.selectionClick();
                      state.rescan();
                    },
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: IdentityCard(state: state),
            ),
          ),
          if (devices.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 12),
                child: _emptyPanel(context, state),
              ),
            )
          else ...<Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                child: WispSectionLabel(
                  title: '可用设备',
                  trailing: state.isScanning ? '扫描中' : null,
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              sliver: SliverList.separated(
                itemCount: devices.length,
                separatorBuilder: (BuildContext context, int index) => const SizedBox(height: 10),
                itemBuilder: (BuildContext context, int index) =>
                    _deviceCard(context, state, devices[index], index),
              ),
            ),
          ],
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: _footerText(context, state),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 公共片段

  Widget _deviceCard(BuildContext context, AppState state, WispDevice device, int index) {
    return StaggeredItem(
      index: index,
      child: DeviceTile(
        device: device,
        onTap: () => showDeviceSheet(context, state, device),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: WispColors.accent(context).withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '发送',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: WispColors.accent(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: _footerText(context, state),
    );
  }

  Widget _footerText(BuildContext context, AppState state) {
    return Column(
      children: <Widget>[
        if (state.hiddenByUsername > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              state.settings.hasUsername
                  ? '已隐藏 ${state.hiddenByUsername} 台其他用户的设备'
                  : '已隐藏 ${state.hiddenByUsername} 台设置了用户名的设备',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Text(
          '下拉可重新扫描 · 右上角可手动输入 IP',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// 扫描状态卡：一眼看清"在不在扫、扫到几台"，手动连接直接可选。
  Widget _scanCard(BuildContext context, AppState state) {
    final bool scanning = state.isScanning;
    final Color tint = scanning ? WispColors.accent(context) : WispColors.success;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: WispColors.surface(context),
        border: Border.all(color: WispColors.line(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              AnimatedContainer(
                duration: WispMotion.base,
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: tint,
                  boxShadow: <BoxShadow>[
                    BoxShadow(color: tint.withValues(alpha: 0.4), blurRadius: 8, spreadRadius: 1),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                scanning ? '正在扫描附近设备' : '扫描已就绪',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: tint),
              ),
              const Spacer(),
              Text(
                '${state.devices.length} 台',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          GhostButton(
            label: '手动输入 IP 连接',
            icon: Icons.link_rounded,
            expand: true,
            onPressed: () => _showManualConnect(context, state),
          ),
        ],
      ),
    );
  }

  void _showManualConnect(BuildContext context, AppState state) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (BuildContext context) => _ManualConnectSheet(state: state),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.icon, required this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: WispColors.surface(context),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: WispColors.line(context)),
            ),
            child: Icon(icon, size: 18, color: WispColors.secondaryText(context)),
          ),
        ),
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

class _ManualConnectSheet extends StatefulWidget {
  const _ManualConnectSheet({required this.state});

  final AppState state;

  @override
  State<_ManualConnectSheet> createState() => _ManualConnectSheetState();
}

class _ManualConnectSheetState extends State<_ManualConnectSheet> {
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
