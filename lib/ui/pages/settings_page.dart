import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/design/app_colors.dart';
import '../../core/design/app_motion.dart';
import '../../core/release_notes.dart';
import '../../models/device.dart';
import '../../models/network.dart';
import '../../services/desktop_service.dart';
import '../../services/settings_service.dart';
import '../../services/update_service.dart';
import '../../state/app_state.dart';
import '../responsive.dart';
import '../widgets/update_sheet.dart';
import '../widgets/wisp_card.dart';

/// 设置页：分组克制，每一项都能一眼看懂"改了会发生什么"。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('设置', style: Theme.of(context).textTheme.displayLarge),
                const SizedBox(height: 4),
                Text(
                  state.receiverRunning
                      ? '接收服务已就绪 · 端口 ${state.settings.port}'
                      : '接收服务未启动',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          sliver: SliverToBoxAdapter(
            // 横屏：分组两列排布，充分利用横向空间；竖屏：单列，与手机一致。
            child: isWideLayout(context)
                ? LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints c) {
                      final double half = (c.maxWidth - 16) / 2;
                      return Wrap(
                        spacing: 16,
                        crossAxisAlignment: WrapCrossAlignment.start,
                        children: <Widget>[
                          for (final Widget group in _buildGroups(context, state))
                            SizedBox(width: half, child: group),
                        ],
                      );
                    },
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _buildGroups(context, state),
                  ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 110),
            child: Center(
              child: Text(
                'Wisp 不联网、不上传、不收集任何数据。\n文件只在你和对面之间流动。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.7),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 所有设置分组。抽成列表是为了横屏时按两列重排，竖屏时保持单列。
  List<Widget> _buildGroups(BuildContext context, AppState state) {
    return <Widget>[
      _Group(
        title: '本机',
                children: <Widget>[
                  _SettingRow(
                    icon: Icons.badge_outlined,
                    title: '设备名称',
                    value: state.settings.alias,
                    onTap: () => _editAlias(context, state),
                  ),
                  _SettingRow(
                    icon: Icons.person_outline_rounded,
                    title: '识别用户名',
                    value: state.settings.hasUsername ? state.settings.username : '不限制',
                    subtitle: state.settings.hasUsername
                        ? '只与同名用户互相可见；对方也要填同一个名字'
                        : '留空则不启用，只与同样留空的设备互相可见',
                    onTap: () => _editUsername(context, state),
                  ),
                  _SettingRow(
                    icon: Icons.visibility_outlined,
                    title: '在局域网中可见',
                    subtitle: '关闭后别人看不到这台设备，但你仍可主动发送',
                    trailing: Switch(
                      value: state.settings.visible,
                      onChanged: state.setVisible,
                    ),
                  ),
                  _SettingRow(
                    icon: Icons.pin_outlined,
                    title: 'PIN 保护',
                    subtitle: state.settings.pinEnabled ? '接收前需要输入 PIN' : '任何人可直接发给你',
                    trailing: Switch(
                      value: state.settings.pinEnabled,
                      onChanged: (bool v) async {
                        if (v && state.settings.pin.isEmpty) {
                          final String? pin = await _askPin(context);
                          if (pin == null) return;
                          await state.setPin(true, pin: pin);
                        } else {
                          await state.setPin(v);
                        }
                      },
                    ),
                  ),
                  _SettingRow(
                    icon: Icons.lock_outline_rounded,
                    title: '加密传输',
                    subtitle: _tlsSubtitle(state),
                    onTap: () => _showFingerprint(context, state),
                    trailing: Switch(
                      value: state.settings.encryption,
                      onChanged: state.setEncryption,
                    ),
                  ),
                ],
              ),
              _Group(
                title: '网络',
                children: <Widget>[
                  _SettingRow(
                    icon: Icons.lan_outlined,
                    title: '本机地址',
                    value: state.localIp ?? '未获取到',
                    subtitle: state.multicastAvailable
                        ? '组播发现可用'
                        : '组播不可用，已回落到扫描模式',
                  ),
                  _SettingRow(
                    icon: Icons.router_outlined,
                    title: '网络接口',
                    value: _interfaceLabel(state),
                    subtitle: '多网卡时指定用哪一块发组播',
                    onTap: () => _pickInterface(context, state),
                  ),
                  _SettingRow(
                    icon: Icons.settings_ethernet_rounded,
                    title: '监听端口',
                    value: '${state.settings.port}',
                    subtitle: '同机跑多个 LocalSend 时改成别的端口',
                    onTap: () => _editPort(context, state),
                  ),
                  _DiscoveryModeSelector(state: state),
                  _SettingRow(
                    icon: Icons.radar_rounded,
                    title: '周期扫描',
                    value: state.settings.scanIntervalSeconds <= 0
                        ? '关闭'
                        : '每 ${state.settings.scanIntervalSeconds} 秒',
                    subtitle: '组播不通时的兜底，扫描整个网段',
                    onTap: () => _pickScanInterval(context, state),
                  ),
                  // 发现功能的自检面板：对方搜不到你时，先看这两行
                  // 就知道是"广播发不出去"还是"一个包都没收到"。
                  _SettingRow(
                    icon: Icons.sensors_rounded,
                    title: '发现状态',
                    value: _discoveryValue(state),
                    subtitle: _discoveryHint(state),
                  ),
                ],
              ),
              // 接收策略 / 白名单 / 安全护栏：单独打包成一个 Widget，横屏两列时
              // 整块留在同一列，不被 Wrap 拆散。
              _receiveSection(context, state),
              _Group(
                title: '外观',
                children: <Widget>[
                  _ThemeSelector(state: state),
                ],
              ),
              _Group(
                title: '系统',
                children: <Widget>[
                  // 开机启动三端都有实现，但能力是运行时回查出来的：
                  // 原生层回报 supported=false（或移动端）就藏掉，不能留一个
                  // 点了没反应、甚至显示"已开启"却根本不会启动的开关。
                  if (state.launchAtLoginSupported) const _LaunchAtLoginRow(),
                  // 下面这几项依赖原生实现（托盘 / 首帧显隐 / Windows 服务），
                  // 各平台实现的并不是同一批：macOS 有关窗驻留菜单栏和桌面浮层
                  // （通知卡 / 气泡），但没有托盘最小化、静默启动和服务守护；
                  // Linux 连通道都没接。悬浮球设置已退役，不再出现在任何平台。
                  if (DesktopService.supportsTrayMinimize)
                    _SettingRow(
                      icon: Icons.close_rounded,
                      title: '关闭时最小化到托盘',
                      subtitle: '点右上角关闭只收进托盘，后台继续接收文件',
                      trailing: Switch(
                        value: state.settings.minimizeToTray,
                        onChanged: state.setMinimizeToTray,
                      ),
                    ),
                  if (DesktopService.supportsSilentStart)
                    _SettingRow(
                      icon: Icons.visibility_off_rounded,
                      title: '静默启动',
                      subtitle: '启动时不显示主窗口，只在托盘里等着收文件（适合开机自启）',
                      trailing: Switch(
                        value: state.settings.silentStart,
                        onChanged: state.setSilentStart,
                      ),
                    ),
                  if (DesktopService.supportsServiceGuard) ...<Widget>[
                    _SettingRow(
                      icon: Icons.health_and_safety_rounded,
                      title: '服务守护',
                      subtitle: _serviceSubtitle(state),
                      trailing: state.serviceBusy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.2),
                            )
                          : Switch(
                              value: state.serviceStatus != 0,
                              onChanged: (bool install) async {
                                final bool ok = await state.setServiceGuard(install);
                                if (!ok && context.mounted) {
                                  ScaffoldMessenger.of(context)
                                    ..hideCurrentSnackBar()
                                    ..showSnackBar(const SnackBar(
                                      content: Text(
                                          '没有完成：需要管理员授权，或已安装但仍在停止中'),
                                    ));
                                }
                              },
                            ),
                    ),
                    // 只在已安装时出现：没装服务就没有"重启"这回事。
                    if (state.serviceStatus != 0)
                      _SettingRow(
                        icon: Icons.restart_alt_rounded,
                        title: '重启守护服务',
                        subtitle: state.serviceBusy
                            ? '正在重启…'
                            : '服务卡在停止中、或应用被反复拉起时用它',
                        trailing: state.serviceBusy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.2),
                              )
                            : Icon(
                                Icons.chevron_right_rounded,
                                size: 20,
                                color: WispColors.secondaryText(context),
                              ),
                        onTap: state.serviceBusy
                            ? null
                            : () async {
                                final bool ok = await state.restartServiceGuard();
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context)
                                  ..hideCurrentSnackBar()
                                  ..showSnackBar(SnackBar(
                                    content: Text(ok
                                        ? '守护服务已重启'
                                        : '没有完成：需要管理员授权，或服务仍在停止中'),
                                  ));
                              },
                      ),
                  ],
                ],
              ),
              _Group(
                title: '关于',
                children: <Widget>[
                  _SettingRow(
                    icon: Icons.info_outline_rounded,
                    title: '版本',
                    value: WispReleaseNotes.currentVersion,
                  ),
                  _SettingRow(
                    icon: Icons.history_edu_rounded,
                    title: '更新日志',
                    value: '共 ${WispReleaseNotes.entries.length} 个版本',
                    onTap: () => _showReleaseNotes(context),
                  ),
                  _SettingRow(
                    icon: Icons.schedule_rounded,
                    title: '自动检查更新',
                    value: WispUpdateCadence.label(state.settings.updateCheckHours),
                    subtitle: state.pendingUpdate == null
                        ? '按频率到点自动比对，发现新版才提醒'
                        : '已发现新版本，点「检查更新」查看详情',
                    onTap: () => _pickUpdateCadence(context, state),
                  ),
                  _SettingRow(
                    icon: Icons.cloud_download_outlined,
                    title: '检查更新',
                    value: state.pendingUpdate == null
                        ? 'v${WispReleaseNotes.currentVersion}'
                        : '新版本 v${state.pendingUpdate!.latestVersion}',
                    onTap: () {
                      showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        constraints: const BoxConstraints(maxWidth: 480),
                        builder: (BuildContext sheetContext) => UpdateSheet(
                          onChecked: () => state.markManualUpdateCheck(),
                        ),
                      );
                    },
                  ),
                  const _SettingRow(
                    icon: Icons.hub_outlined,
                    title: '协议',
                    value: 'LocalSend v2.2',
                    subtitle: '可与官方 LocalSend 客户端互通',
                  ),
                  _SettingRow(
                    icon: Icons.fingerprint_rounded,
                    title: '本机指纹',
                    value: _shortFingerprint(state.settings.fingerprint),
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: state.settings.fingerprint));
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(const SnackBar(content: Text('指纹已复制')));
                    },
                  ),
                ],
              ),
    ];
  }

  /// 发现状态的一句话结论。区分三种情况：组播没加入 / 加入了但没收到任何包 / 正常。
  static String _discoveryValue(AppState state) {
    if (!state.multicastAvailable) return '仅扫描';
    final DateTime? peer = state.discoveryLastPeerAt;
    if (peer == null) return '组播已加入 · 暂无广播';
    return '组播 · ${_clock(peer)} 收到广播';
  }

  static String _discoveryHint(AppState state) {
    final DateTime? sent = state.discoveryLastAnnounceAt;
    final String send = sent == null ? '广播尚未发出' : '最近广播 ${_clock(sent)}';
    if (!state.multicastAvailable) {
      return '$send。组播没加入，别人搜不到你，只能靠扫描主动找别人。';
    }
    if (state.discoveryLastPeerAt == null) {
      return '$send。一个包都没收到——多半是路由器隔离了组播，或防火墙拦了 UDP。';
    }
    return '$send。对方搜不到你时，检查防火墙是否放行 UDP 53317。';
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  static String _serviceSubtitle(AppState state) {
    switch (state.serviceStatus) {
      case 2:
        return '已安装并运行：应用被误关或崩溃时自动拉起，开机自动恢复';
      case 1:
        return '已安装但未运行，重启服务后生效';
      default:
        return '安装 Windows 服务常驻后台，防止意外退出（需要管理员授权）';
    }
  }

  /// 加密状态的一句话结论：证书在不在、现在到底走没走 TLS。
  /// 不能把"开关打开"当成"已加密"——证书加载失败时开关是开的、链路仍是明文。
  static String _tlsSubtitle(AppState state) {
    final String? fp = state.certFingerprint;
    if (fp == null) return '未找到证书，当前走明文 HTTP';
    final String short = fp.split(':').take(4).join(':');
    if (!state.settings.encryption) return '已关闭，当前走明文 HTTP';
    return state.encrypted ? 'TLS 已启用 · 指纹 $short…' : '证书就绪，服务重启后生效';
  }

  void _showFingerprint(BuildContext context, AppState state) {
    final String? fp = state.certFingerprint;
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: WispColors.surface(dialogContext),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('证书指纹'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SelectableText(
              fp ?? '没有可用证书',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                color: WispColors.secondaryText(dialogContext),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '这是内置自签证书的 SHA-256 指纹，与 openssl 的输出一致。\n'
              '局域网直连无法走 CA 链，信任模型是"指纹 + 同一网段"：'
              '首传时两端各看一次，指纹一致即可。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Text(
              '所有安装包共用这一张证书，它防的是同网段的旁听，不用于区分"是哪台机器"。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  static String _interfaceLabel(AppState state) {    final String? id = state.settings.networkInterface;
    if (id == null || id.isEmpty) return '自动';
    for (final NetworkInterfaceInfo info in state.interfaces) {
      if (info.id == id) return info.name;
    }
    return '自动';
  }

  static String _shortFingerprint(String fingerprint) {
    if (fingerprint.length <= 16) return fingerprint.toUpperCase();
    return '${fingerprint.substring(0, 8)}…${fingerprint.substring(fingerprint.length - 4)}'.toUpperCase();
  }

  Future<void> _editAlias(BuildContext context, AppState state) async {
    final TextEditingController controller = TextEditingController(text: state.settings.alias);
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: WispColors.surface(dialogContext),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('设备名称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
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
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value != null && value.trim().isNotEmpty) await state.setAlias(value);
  }

  /// 编辑识别用户名。留空表示不启用这个限制。
  Future<void> _editUsername(BuildContext context, AppState state) async {
    final TextEditingController controller =
        TextEditingController(text: state.settings.username);
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: WispColors.surface(dialogContext),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('识别用户名'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '填了之后，只与用户名相同的设备互相可见：你看不到别人，别人也看不到你。'
              '留空表示不启用这个限制，此时只能看到同样留空的设备。',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 32,
              decoration: InputDecoration(
                counterText: '',
                hintText: '例如：zhangsan',
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
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value != null) await state.setUsername(value);
  }

  /// 修改监听端口。
  Future<void> _editPort(BuildContext context, AppState state) async {
    final TextEditingController controller =
        TextEditingController(text: '${state.settings.port}');
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: WispColors.surface(dialogContext),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('监听端口'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '默认 53317，与官方 LocalSend 一致。同机跑两个时改成别的端口。',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 5,
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
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value == null) return;
    if (!context.mounted) return;
    final int? port = int.tryParse(value.trim());
    if (port == null || port < 1024 || port > 65535) {
      _toast(context, '端口需要在 1024 - 65535 之间');
      return;
    }
    await state.setPort(port);
  }

  /// 选择用于发现设备的网卡。
  Future<void> _pickInterface(BuildContext context, AppState state) async {
    if (state.interfaces.isEmpty) {
      await state.rescan();
      if (!context.mounted) return;
      if (state.interfaces.isEmpty) {
        _toast(context, '没有找到可用的局域网网卡');
        return;
      }
    }

    final List<NetworkInterfaceInfo> options = <NetworkInterfaceInfo>[
      const NetworkInterfaceInfo(name: '自动', address: '', isVirtual: false),
      ...state.interfaces,
    ];

    final String? picked = await showModalBottomSheet<String>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (BuildContext sheetContext) => SafeArea(
        child: RadioGroup<String>(
          groupValue: state.settings.networkInterface ?? '',
          onChanged: (String? v) => Navigator.of(sheetContext).pop(v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Text('选择网络接口', style: Theme.of(sheetContext).textTheme.headlineMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  '多网卡时，组播走哪一块决定了能不能发现设备。',
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
              ),
              for (final NetworkInterfaceInfo info in options)
                RadioListTile<String>(
                  value: info.id,
                  title: Text(info.name),
                  subtitle: info.address.isEmpty
                      ? const Text('自动选择默认网卡')
                      : Text('${info.address}${info.isVirtual ? ' · 虚拟网卡' : ''}'),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    if (picked == null) return;
    await state.setNetworkInterface(picked.isEmpty ? null : picked);
  }

  /// 「关于 → 更新日志」：按版本倒序滚动查看每次发布改了什么。
  /// 高度最多占屏 72%，内容多时内部滚动，不把弹层顶出屏幕。
  void _showReleaseNotes(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (BuildContext sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
                child: Text(
                  '更新日志',
                  style: Theme.of(sheetContext).textTheme.headlineMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  '共 ${WispReleaseNotes.entries.length} 个版本，当前 v${WispReleaseNotes.currentVersion}',
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
                  itemCount: WispReleaseNotes.entries.length,
                  itemBuilder: (BuildContext itemContext, int index) =>
                      _ReleaseEntryTile(entry: WispReleaseNotes.entries[index]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 选择周期扫描的间隔。
  Future<void> _pickScanInterval(BuildContext context, AppState state) async {
    const Map<String, int> options = <String, int>{
      '关闭': 0,
      '每 15 秒': 15,
      '每 30 秒': 30,
      '每 60 秒': 60,
    };
    final int? picked = await showModalBottomSheet<int>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (BuildContext sheetContext) => SafeArea(
        child: RadioGroup<int>(
          groupValue: state.settings.scanIntervalSeconds,
          onChanged: (int? v) => Navigator.of(sheetContext).pop(v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final MapEntry<String, int> entry in options.entries)
                RadioListTile<int>(
                  value: entry.value,
                  title: Text(entry.key),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    await state.setScanInterval(picked);
  }

  /// 选择自动检查更新的频率。选「关闭」后只保留手动检查。
  Future<void> _pickUpdateCadence(BuildContext context, AppState state) async {
    final int? picked = await showModalBottomSheet<int>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (BuildContext sheetContext) => SafeArea(
        // 小屏（600 高）下标题 + 说明 + 四个选项会顶出弹层，套一层可滚兜底。
        child: SingleChildScrollView(
          child: RadioGroup<int>(
            groupValue: state.settings.updateCheckHours,
            onChanged: (int? v) => Navigator.of(sheetContext).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                  child: Text('自动检查更新', style: Theme.of(sheetContext).textTheme.headlineMedium),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Text(
                    '到点后台静默比对一次，发现新版本才提醒；不会自动下载安装。',
                    style: Theme.of(sheetContext).textTheme.bodySmall,
                  ),
                ),
                for (final MapEntry<String, int> entry in WispUpdateCadence.options.entries)
                  RadioListTile<int>(
                    value: entry.value,
                    title: Text(entry.key),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked == null) return;
    await state.setUpdateCheckHours(picked);
  }

  // ---------------------------------------------------------------------------
  // 接收策略 / 白名单 / 安全护栏
  // ---------------------------------------------------------------------------

  /// 「接收」分组。打包成一个 Widget，横屏两列重排时整块留在同一列。
  Widget _receiveSection(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
            child: Text(
              '接收',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
            ),
          ),
          _policyCard(context, state),
          const SizedBox(height: 12),
          _trustedCard(context, state),
          const SizedBox(height: 12),
          // 保留「保存位置」：与旧的自动接收开关同组，测试也依赖这个文案。
          WispCard(
            padding: EdgeInsets.zero,
            child: _SettingRow(
              icon: Icons.folder_open_rounded,
              title: '保存位置',
              value: state.settings.saveDirectory ?? '系统下载目录 / Wisp',
              onTap: () => _pickDirectory(context, state),
            ),
          ),
          const SizedBox(height: 12),
          _warningCard(context),
          const SizedBox(height: 12),
          _guardrailCard(context, state),
          const SizedBox(height: 12),
          _scopeCard(context, state),
        ],
      ),
    );
  }

  /// 三态接收策略卡片。选中项写回 [AppState.setReceivePolicy]。
  Widget _policyCard(BuildContext context, AppState state) {
    final ReceivePolicy current = state.settings.receivePolicy;
    return WispCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '接收策略',
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '决定哪些设备发来的文件需要你点一次「接收」',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          // 三个档位都是「自动接收」的开关。这里刻意留一处精确
          // Text('自动接收')，兼容 settings_platform_gate_test 的文案断言；
          // 其余提到自动接收的文案都写成长句，避免 find.text 精确匹配撞车。
          Text(
            '自动接收',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: WispColors.secondaryText(context),
                ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (int i = 0; i < _policyDefs.length; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                        right: i == _policyDefs.length - 1 ? 0 : 8),
                    child: _policyOption(
                      context,
                      state,
                      _policyDefs[i],
                      selected: current == _policyDefs[i].policy,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 单个档位：沿用 _ThemeSelector 的 segmented 风格（GestureDetector +
  /// AnimatedContainer），选中态用品牌青绿描边、浅色底和右上角勾。
  Widget _policyOption(
    BuildContext context,
    AppState state,
    _PolicyDef def, {
    required bool selected,
  }) {
    final Color accent = WispColors.accent(context);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        state.setReceivePolicy(def.policy);
      },
      child: AnimatedContainer(
        duration: WispMotion.base,
        curve: WispMotion.enter,
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.08)
              : WispColors.surfaceAlt(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? accent : WispColors.line(context),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Stack(
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  def.icon,
                  size: 18,
                  color: selected
                      ? accent
                      : WispColors.secondaryText(context),
                ),
                const SizedBox(height: 8),
                Text(
                  def.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? accent
                        : Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  def.subtitle,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.4,
                    color: WispColors.secondaryText(context),
                  ),
                ),
              ],
            ),
            if (selected)
              Positioned(
                right: 0,
                top: 0,
                child: Icon(Icons.check_circle_rounded,
                    size: 16, color: accent),
              ),
          ],
        ),
      ),
    );
  }

  /// 白名单设备列表 + 「＋ 添加设备」。数据只认
  /// [WispSettings.trustedFingerprints]，与身份卡的「免确认接收」是同一份。
  Widget _trustedCard(BuildContext context, AppState state) {
    final List<String> trusted = state.settings.trustedFingerprints;
    return WispCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '白名单设备 · ${trusted.length} 台',
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              OutlinedButton(
                onPressed: () => _showAddTrustedDevice(context, state),
                style: OutlinedButton.styleFrom(
                  foregroundColor: WispColors.accent(context),
                  side: BorderSide(color: WispColors.line(context)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  textStyle: const TextStyle(fontSize: 12),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('＋ 添加设备'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '按稳定标识（fingerprint）匹配，换 Wi-Fi、改别名都仍然生效',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          if (trusted.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                '还没有白名单设备。点「＋ 添加设备」从附近设备里挑一台。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else
            ...<Widget>[
              for (final String fingerprint in trusted)
                _trustedRow(context, state, fingerprint),
            ],
        ],
      ),
    );
  }

  /// 单条白名单记录。别名 / 在线状态 / 曾用 IP 尽量从在线设备或会话里补，
  /// 都取不到就显示「离线 · 记录仍在这里」+ fingerprint 短码。
  Widget _trustedRow(
      BuildContext context, AppState state, String fingerprint) {
    WispDevice? live;
    for (final WispDevice device in state.devices) {
      if (device.fingerprint == fingerprint) {
        live = device;
        break;
      }
    }
    String? pastAlias;
    String? pastIp;
    for (final conversation in state.conversations) {
      if (conversation.peerKey == fingerprint) {
        pastAlias = conversation.peerAlias;
        pastIp = conversation.peerIp;
        break;
      }
    }
    final bool online = live != null;
    final bool found = live != null || pastAlias != null;
    final String alias =
        live?.alias ?? pastAlias ?? '离线 · 记录仍在这里';
    final String ip = live?.ip ?? pastIp ?? '';
    final String detail = ip.isEmpty ? '记录仍在这里' : '曾用 $ip';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(
            online ? Icons.devices_rounded : Icons.devices_other_rounded,
            size: 20,
            color: WispColors.secondaryText(context),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        alias,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    if (found) ...<Widget>[
                      const SizedBox(width: 6),
                      _onlineChip(context, online),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${_trustedShortCode(fingerprint)} · $detail',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures()
                        ],
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: () {
              state.toggleTrusted(fingerprint);
            },
            style: TextButton.styleFrom(
              foregroundColor: WispColors.secondaryText(context),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('移除'),
          ),
        ],
      ),
    );
  }

  Widget _onlineChip(BuildContext context, bool online) {
    final Color color =
        online ? WispColors.mint : WispColors.secondaryText(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        online ? '在线' : '离线',
        style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  /// 安全警告：白名单是「免打扰」不是身份认证，稳定标识由对端自报。
  Widget _warningCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WispColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: WispColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.warning_amber_rounded,
              size: 18, color: WispColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '自动接收允许这些设备直接写入磁盘',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '稳定标识由对端自报，接收端没有证书验证，因此白名单是'
                  '「免打扰」，不是身份认证。请勿在不可信的局域网里使用'
                  '「全部自动接收」；开启 PIN 保护时，PIN 校验依然生效。',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 护栏：超限回落确认、无稳定标识一律询问、PIN 保护当前状态。
  /// 数值统一取 [WispProtocol]，不在这里硬编码 20 / 2 GB。
  Widget _guardrailCard(BuildContext context, AppState state) {
    final String limit =
        '${WispProtocol.maxAutoAcceptFiles} 个文件 / 声明总量超过 '
        '${_bytesLabel(WispProtocol.maxAutoAcceptBytes)}';
    return WispCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '护栏',
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          _SettingRow(
            icon: Icons.shield_outlined,
            title: '超限回落确认',
            subtitle: '单请求超过 $limit 时，仍然弹确认',
            trailing: Icon(Icons.check_circle_rounded,
                size: 18, color: WispColors.accent(context)),
          ),
          Divider(height: 1, indent: 52, color: WispColors.line(context)),
          _SettingRow(
            icon: Icons.info_outline_rounded,
            title: '无稳定标识的设备一律询问',
            subtitle: '老版本或匿名设备不能被加入白名单',
            trailing: Icon(Icons.check_circle_rounded,
                size: 18, color: WispColors.accent(context)),
          ),
          Divider(height: 1, indent: 52, color: WispColors.line(context)),
          _SettingRow(
            icon: Icons.lock_outline_rounded,
            title: 'PIN 保护',
            subtitle: state.settings.pinEnabled
                ? '当前已开启；自动接收也要通过 PIN 校验'
                : '当前未开启；开启后自动接收也要通过 PIN 校验',
            trailing: Text(
              state.settings.pinEnabled ? '已开启' : '未开启',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: state.settings.pinEnabled
                        ? WispColors.accent(context)
                        : WispColors.secondaryText(context),
                  ),
            ),
          ),
        ],
      ),
    );
  }

  /// 当前生效范围：免确认设备数 / 仍需同意设备数，以及完成后的通知说明。
  Widget _scopeCard(BuildContext context, AppState state) {
    final ReceivePolicy policy = state.settings.receivePolicy;
    final List<String> trusted = state.settings.trustedFingerprints;
    int exempt = 0;
    int consent = 0;
    switch (policy) {
      case ReceivePolicy.ask:
        exempt = 0;
        consent = state.devices.length;
        break;
      case ReceivePolicy.trusted:
        exempt = trusted.length;
        consent = state.devices
            .where((WispDevice d) => !trusted.contains(d.fingerprint))
            .length;
        break;
      case ReceivePolicy.all:
        exempt = state.devices.length;
        consent = 0;
        break;
    }
    return WispCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '当前生效范围',
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(child: _metric(context, exempt, '台设备免确认接收')),
              const SizedBox(width: 10),
              Expanded(child: _metric(context, consent, '台设备仍需你同意')),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '自动接收不会弹「接收 / 忽略」，但完成后仍会发一条通知，'
            '可以点开所在目录。',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _metric(BuildContext context, int value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: WispColors.surfaceAlt(context),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: <Widget>[
          Text(
            '$value',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: WispColors.accent(context),
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// 「＋ 添加设备」的轻量选择器：只列 fingerprint 非空且还没在名单里的
  /// 在线设备，选中后走 [AppState.toggleTrusted] 加入。无稳定标识的老设备
  /// 被过滤掉并给出提示（它们不能被加入白名单）。
  Future<void> _showAddTrustedDevice(
      BuildContext context, AppState state) async {
    final List<String> trusted = state.settings.trustedFingerprints;
    final List<WispDevice> eligible = <WispDevice>[];
    int anonymous = 0;
    for (final WispDevice device in state.devices) {
      final String fingerprint = device.fingerprint;
      if (fingerprint.trim().isEmpty) {
        anonymous++;
        continue;
      }
      if (trusted.contains(fingerprint)) continue;
      eligible.add(device);
    }

    final WispDevice? picked = await showDialog<WispDevice>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: WispColors.surface(dialogContext),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('添加白名单设备'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (eligible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '附近没有可添加的设备。等对方出现在「附近」列表里再来。',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: WispColors.secondaryText(dialogContext),
                      ),
                    ),
                  )
                else
                  ...<Widget>[
                    for (final WispDevice device in eligible)
                      ListTile(
                        leading: Icon(Icons.devices_rounded,
                            size: 20,
                            color: WispColors.secondaryText(dialogContext)),
                        title: Text(device.alias),
                        subtitle: Text(
                          '${device.shortFingerprint}… · ${device.ip}',
                          style: Theme.of(dialogContext).textTheme.bodySmall,
                        ),
                        onTap: () =>
                            Navigator.of(dialogContext).pop(device),
                      ),
                  ],
                if (anonymous > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '已过滤 $anonymous 台无稳定标识的设备：'
                      '老版本或匿名设备不能被加入白名单。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: WispColors.warning,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await state.toggleTrusted(picked.fingerprint);
  }

  /// 白名单行里的 fingerprint 短码：前 8 位大写 + …。
  static String _trustedShortCode(String fingerprint) {
    if (fingerprint.isEmpty) return '—';
    final String head = fingerprint.length <= 8
        ? fingerprint.toUpperCase()
        : fingerprint.substring(0, 8).toUpperCase();
    return '$head…';
  }

  /// 把 [WispProtocol.maxAutoAcceptBytes] 格式化成「2 GB」这类文案。
  static String _bytesLabel(int bytes) {
    const int gb = 1024 * 1024 * 1024;
    if (bytes >= gb && bytes % gb == 0) return '${bytes ~/ gb} GB';
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    return '${bytes ~/ (1024 * 1024)} MB';
  }

  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _askPin(BuildContext context) async {
    final TextEditingController controller = TextEditingController();
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: WispColors.surface(dialogContext),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('设置 PIN'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            counterText: '',
            hintText: '6 位数字',
            filled: true,
            fillColor: WispColors.surfaceAlt(dialogContext),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (value == null || value.length < 4) return null;
    return value;
  }

  Future<void> _pickDirectory(BuildContext context, AppState state) async {
    try {
      final String? path = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择接收文件的保存位置');
      if (path != null) await state.setSaveDirectory(path);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('无法打开目录选择器')));
      }
    }
  }
}

class _DiscoveryModeSelector extends StatelessWidget {
  const _DiscoveryModeSelector({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final DiscoveryMode mode = state.settings.discoveryMode;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.travel_explore_rounded, size: 18, color: WispColors.secondaryText(context)),
              const SizedBox(width: 10),
              Text('发现方式', style: Theme.of(context).textTheme.bodyLarge),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            mode.hint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: WispColors.surfaceAlt(context),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: <Widget>[
                for (final DiscoveryMode option in DiscoveryMode.values)
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        state.setDiscoveryMode(option);
                      },
                      child: AnimatedContainer(
                        duration: WispMotion.base,
                        curve: WispMotion.enter,
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        decoration: BoxDecoration(
                          color: mode == option ? WispColors.surface(context) : Colors.transparent,
                          borderRadius: BorderRadius.circular(11),
                          boxShadow: mode == option
                              ? <BoxShadow>[
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.06),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ]
                              : null,
                        ),
                        child: Text(
                          switch (option) {
                            DiscoveryMode.auto => '自动',
                            DiscoveryMode.multicast => '组播',
                            DiscoveryMode.scan => '扫描',
                          },
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: mode == option ? FontWeight.w600 : FontWeight.w500,
                            color: mode == option
                                ? WispColors.accent(context)
                                : WispColors.secondaryText(context),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeSelector extends StatelessWidget {
  const _ThemeSelector({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ThemeMode mode = state.settings.themeMode;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.contrast_rounded, size: 18, color: WispColors.secondaryText(context)),
              const SizedBox(width: 10),
              Text('主题', style: Theme.of(context).textTheme.bodyLarge),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: WispColors.surfaceAlt(context),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: <Widget>[
                for (final MapEntry<String, ThemeMode> entry in const <String, ThemeMode>{
                  '跟随系统': ThemeMode.system,
                  '浅色': ThemeMode.light,
                  '深色': ThemeMode.dark,
                }.entries)
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        state.setThemeMode(entry.value);
                      },
                      child: AnimatedContainer(
                        duration: WispMotion.base,
                        curve: WispMotion.enter,
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        decoration: BoxDecoration(
                          color: mode == entry.value
                              ? WispColors.surface(context)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(11),
                          boxShadow: mode == entry.value
                              ? <BoxShadow>[
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.06),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ]
                              : null,
                        ),
                        child: Text(
                          entry.key,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: mode == entry.value ? FontWeight.w600 : FontWeight.w500,
                            color: mode == entry.value
                                ? WispColors.accent(context)
                                : WispColors.secondaryText(context),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
            child: Text(
              title,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
            ),
          ),
          WispCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                for (int i = 0; i < children.length; i++) ...<Widget>[
                  children[i],
                  if (i != children.length - 1)
                    Divider(height: 1, indent: 52, color: WispColors.line(context)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: WispColors.secondaryText(context)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: Theme.of(context).textTheme.bodyLarge),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (value != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  value!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: WispColors.secondaryText(context),
                      ),
                ),
              ),
            if (trailing != null) trailing!,
            if (onTap != null && trailing == null)
              Icon(Icons.chevron_right_rounded, size: 18, color: WispColors.secondaryText(context)),
          ],
        ),
      ),
    );
  }
}

/// 更新日志弹层里的单个版本块：版本徽章 + 当前版本标记 + 改动清单。
class _ReleaseEntryTile extends StatelessWidget {
  const _ReleaseEntryTile({required this.entry});

  final WispReleaseEntry entry;

  @override
  Widget build(BuildContext context) {
    final bool current = entry.isCurrent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: current ? WispColors.teal : WispColors.surfaceAlt(context),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'v${entry.version}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                    color: current ? Colors.white : WispColors.secondaryText(context),
                  ),
                ),
              ),
              if (current) ...<Widget>[
                const SizedBox(width: 8),
                Text(
                  '当前版本',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: WispColors.teal,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          for (final String change in entry.changes)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: current
                            ? WispColors.teal.withValues(alpha: 0.7)
                            : WispColors.secondaryText(context).withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(change, style: Theme.of(context).textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 开机启动开关。
///
/// 单独做成 StatefulWidget 是为了**每次进设置页都回查一次系统状态**：
/// 用户完全可能刚在系统设置里禁用了登录项，只靠应用启动时那次回查会
/// 显示一个过期的开关。没初始化完（ready=false）时不查，避免启动期
/// 多余的通道调用。
class _LaunchAtLoginRow extends StatefulWidget {
  const _LaunchAtLoginRow();

  @override
  State<_LaunchAtLoginRow> createState() => _LaunchAtLoginRowState();
}

class _LaunchAtLoginRowState extends State<_LaunchAtLoginRow> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final AppState state = context.read<AppState>();
      if (state.ready) state.refreshLaunchAtLogin();
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    return _SettingRow(
      icon: Icons.power_settings_new_rounded,
      title: '开机启动',
      subtitle: '登录系统后自动运行 Wisp，在后台等着接收文件',
      trailing: state.launchAtLoginBusy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            )
          : Switch(
              value: state.launchAtLoginEnabled,
              onChanged: (bool enabled) async {
                final bool ok = await state.setLaunchAtLogin(enabled);
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(
                      content: Text(
                          '没有完成：系统没有接受这个设置，请到系统的「启动项 / 登录项」里手动添加 Wisp'),
                    ));
                }
              },
            ),
    );
  }
}

/// 接收策略三态的静态描述：枚举值 + 文案 + 图标。
class _PolicyDef {
  const _PolicyDef(this.policy, this.title, this.subtitle, this.icon);

  final ReceivePolicy policy;
  final String title;
  final String subtitle;
  final IconData icon;
}

const List<_PolicyDef> _policyDefs = <_PolicyDef>[
  _PolicyDef(
    ReceivePolicy.ask,
    '每次询问',
    '所有设备都弹确认卡，最保守',
    Icons.visibility_outlined,
  ),
  _PolicyDef(
    ReceivePolicy.trusted,
    '仅白名单设备',
    '信任的设备直接落盘，其余仍需同意',
    Icons.shield_outlined,
  ),
  _PolicyDef(
    ReceivePolicy.all,
    '全部自动接收',
    '任何设备都不再询问，风险自负',
    Icons.folder_open_rounded,
  ),
];
