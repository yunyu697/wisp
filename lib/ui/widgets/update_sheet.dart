import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/release_notes.dart';
import '../../core/utils/external.dart';
import '../../core/design/app_colors.dart';
import '../../services/update_installer.dart';
import '../../services/update_service.dart';

/// 「检查更新」弹层：打开即发起检查，无论成败都列出下载入口
/// （官方源 + 加速镜像），检查失败也能手动取最新版。
///
/// 发现新版本时提供三个动作：
/// · 一键更新 —— 下载安装包并自动完成安装（Windows 静默装完自动起新版；
///   macOS 挂载 dmg 拷进 /Applications）；
/// · 仅下载 —— 只把安装包下到本地，完成后提示安装方式；
/// · 打开下载页 —— 跳 GitHub Release 页面自己挑。
///
/// [checkOverride] 供测试注入：null 走真实网络检查。
/// [onChecked] 在一次检查结束后回调（无论成败），
/// 用于刷新自动检查的时间戳，避免刚手动查完又被自动检查重复请求。
class UpdateSheet extends StatefulWidget {
  const UpdateSheet({
    super.key,
    this.checkOverride,
    this.onChecked,
    String? currentVersion,
  }) : currentVersion = currentVersion ?? WispReleaseNotes.currentVersion;

  final Future<WispUpdateInfo?> Function()? checkOverride;
  final VoidCallback? onChecked;

  /// 「当前 vX.Y.Z」里显示的版本。生产环境用真实版本；
  /// 测试传固定值，否则每发一版都要重画 golden（差几十像素，纯噪音）。
  final String currentVersion;

  @override
  State<UpdateSheet> createState() => _UpdateSheetState();
}

enum _Phase { idle, downloading, installing, done, failed }

class _UpdateSheetState extends State<UpdateSheet> {
  late Future<WispUpdateInfo?> _future;

  _Phase _phase = _Phase.idle;
  double? _progress; // null = 总长未知，进度条转圈
  String _resultText = '';

  /// 用户在「下载源」下拉里选中的线路。默认官方直连。
  WispUpdateSourceOption _source = WispUpdateSource.downloadOptions.first;

  /// 「仅下载」下好的安装包路径——非空时才在结果区给出「安装」按钮。
  String? _downloadedPath;

  @override
  void initState() {
    super.initState();
    _future = _check();
  }

  Future<WispUpdateInfo?> _check() async {
    try {
      return await widget.checkOverride?.call() ?? await WispUpdateService.check();
    } finally {
      widget.onChecked?.call();
    }
  }

  void _retry() => setState(() => _future = _check());

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text(
                '检查更新',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '当前 v${widget.currentVersion}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: FutureBuilder<WispUpdateInfo?>(
                  future: _future,
                  builder: (BuildContext context,
                      AsyncSnapshot<WispUpdateInfo?> snapshot) {
                    final Widget status = _statusBlock(context, snapshot);
                    final WispUpdateInfo? info = snapshot.data;
                    final bool newer = info != null &&
                        WispUpdateService.isNewer(
                            info.latestVersion, widget.currentVersion);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        status,
                        if (newer) ...<Widget>[
                          const SizedBox(height: 6),
                          _actionArea(context),
                        ],
                        const SizedBox(height: 6),
                        ..._downloadSection(context, snapshot.data),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 检查状态区：加载 / 已是最新 / 发现新版本 / 失败（带重试）。
  Widget _statusBlock(BuildContext context, AsyncSnapshot<WispUpdateInfo?> snapshot) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            SizedBox(width: 10),
            Text('正在检查更新…'),
          ],
        ),
      );
    }

    final WispUpdateInfo? info = snapshot.data;
    if (info == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: <Widget>[
            const Icon(Icons.cloud_off_rounded,
                size: 18, color: WispColors.warning),
            const SizedBox(width: 8),
            const Expanded(child: Text('连不上更新源，检查网络后重试')),
            TextButton(onPressed: _retry, child: const Text('重试')),
          ],
        ),
      );
    }

    final bool newer =
        WispUpdateService.isNewer(info.latestVersion, widget.currentVersion);
    if (!newer) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: <Widget>[
            Icon(Icons.check_circle_outline_rounded,
                size: 18, color: WispColors.success),
            const SizedBox(width: 8),
            Expanded(child: Text('已是最新版本（v${info.latestVersion}）')),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: WispColors.teal,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'v${info.latestVersion}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '发现新版本',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: WispColors.teal,
                ),
              ),
            ],
          ),
          if (info.notes != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              info.notes!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 三按钮动作区：一键更新 / 仅下载 / 打开下载页
  // ---------------------------------------------------------------------------

  Widget _actionArea(BuildContext context) {
    switch (_phase) {
      case _Phase.downloading:
        return _progressBlock(
          context,
          determinate: _progress,
          label: _progress == null
              ? '正在下载安装包…'
              : '正在下载安装包… ${(_progress! * 100).toStringAsFixed(0)}%',
        );
      case _Phase.installing:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
              SizedBox(width: 10),
              Text('下载完成，正在安装…'),
            ],
          ),
        );
      case _Phase.done:
      case _Phase.failed:
        final bool failed = _phase == _Phase.failed;
        // 「仅下载」下完之后：文件就在用户的下载目录里，这里直接给出安装入口。
        // 不能只丢一句"请手动安装"——Windows 的 UAC、macOS 的挂载都还是我们
        // 能替用户做的，用户没必要自己去找那个文件。
        final String? pending = failed ? null : _downloadedPath;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: WispUpdateResultCard(
            failed: failed,
            message: _resultText,
            onInstall: pending != null && WispUpdateInstaller.supportsAutoInstall
                ? () => _install(pending, restart: true)
                : null,
            onDismiss: () => setState(() {
              _phase = _Phase.idle;
              _downloadedPath = null;
            }),
          ),
        );
      case _Phase.idle:
        final bool auto = WispUpdateInstaller.supportsAutoInstall;
        return Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  if (auto) ...<Widget>[
                    // 不给按钮配图标：三等分的宽度里 icon 会把文字挤成省略号。
                    Expanded(
                      child: FilledButton(
                        onPressed: _autoUpdate,
                        child: const Text('一键更新', overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _downloadOnly,
                      child: const Text('仅下载', overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton(
                      onPressed: _openReleasePage,
                      child: const Text('打开下载页', overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _sourceRow(context),
            ],
          ),
        );
    }
  }

  /// 下载源下拉：一键更新与仅下载都按这里选的线路走。
  ///
  /// 默认官方直连。选了镜像也会在它失败后自动退回官方源重试——镜像站
  /// 随时可能挂，让用户回来重选一遍纯属折腾。
  Widget _sourceRow(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(Icons.route_rounded,
            size: 16, color: WispColors.secondaryText(context)),
        const SizedBox(width: 6),
        Text('下载源', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: 10),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<WispUpdateSourceOption>(
                value: _source,
                isDense: true,
                borderRadius: BorderRadius.circular(12),
                style: Theme.of(context).textTheme.bodyMedium,
                items: <DropdownMenuItem<WispUpdateSourceOption>>[
                  for (final WispUpdateSourceOption option
                      in WispUpdateSource.downloadOptions)
                    DropdownMenuItem<WispUpdateSourceOption>(
                      value: option,
                      child: Text(option.label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (WispUpdateSourceOption? picked) {
                  if (picked == null || picked == _source) return;
                  setState(() => _source = picked);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _progressBlock(BuildContext context,
      {required double? determinate, required String label}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
            ],
          ),
          const SizedBox(height: 10),
          if (determinate != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: determinate.clamp(0.0, 1.0),
                minHeight: 6,
              ),
            )
          else
            const LinearProgressIndicator(minHeight: 6),
        ],
      ),
    );
  }

  /// 按当前选中的下载源下载；进度实时刷进 [_progress]。
  /// 失败时把 [_phase] 置为 failed 并返回 null。
  ///
  /// [verified] 为 true 时要求清单提供 sha256 并逐字节比对（一键更新必须走这条）；
  /// 「仅下载」放宽到"有校验值就比、没有就下"，用户自己决定装不装。
  /// [toUserDir] 为 true 时落到用户的默认下载目录（仅下载），否则落临时目录。
  Future<String?> _runDownload({
    required bool verified,
    required bool toUserDir,
  }) async {
    setState(() {
      _phase = _Phase.downloading;
      _progress = null;
    });
    try {
      final Directory? dir = toUserDir
          ? await WispUpdateInstaller.userDownloadDir()
          : null;
      final String path = await WispUpdateInstaller.download(
        requireVerified: verified,
        source: _source,
        targetDir: dir,
        onProgress: (int received, int total) {
          if (!mounted) return;
          setState(() {
            _progress = total > 0 ? received / total : null;
          });
        },
      );
      return path;
    } catch (e) {
      if (!mounted) return null;
      setState(() {
        _phase = _Phase.failed;
        _resultText = '下载失败：$e';
      });
      return null;
    }
  }

  /// 一键更新：下载 + 自动安装 + 自动重启。
  Future<void> _autoUpdate() async {
    final String? path = await _runDownload(verified: true, toUserDir: false);
    if (path == null || !mounted) return;
    await _install(path);
  }

  /// 装一个已经下好的安装包。[restart] 为 true 时装完自动重启（macOS 需要
  /// 自己拉起新版；Windows 由安装器的静默启动项负责，restartPath 为 null）。
  Future<void> _install(String path, {bool restart = true}) async {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.installing;
      _downloadedPath = null;
    });
    UpdateInstallOutcome outcome;
    try {
      outcome = await WispUpdateInstaller.install(path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _resultText = '安装失败：$e';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _phase = outcome.ok ? _Phase.done : _Phase.failed;
      _resultText = outcome.message;
    });
    // 留一点时间让用户看清"正在重启"，否则窗口突然消失像是崩了。
    final String? restartTo = outcome.restartPath;
    if (restart && outcome.ok && restartTo != null) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted) return;
      await WispUpdateInstaller.restartInto(restartTo);
    }
  }

  /// 仅下载：下到用户的下载目录，下完在结果区给出「安装」按钮。
  Future<void> _downloadOnly() async {
    final String? path = await _runDownload(verified: false, toUserDir: true);
    if (path == null || !mounted) return;
    setState(() {
      _phase = _Phase.done;
      _downloadedPath = path;
      _resultText = WispUpdateInstaller.supportsAutoInstall
          ? '安装包已下载到 $path，可以直接点「安装」。'
          : '安装包已下载到 $path，请手动安装。';
    });
  }

  /// 打开下载页：Release 页面里各平台产物自己挑。
  Future<void> _openReleasePage() async {
    final ExternalOpenResult result =
        await openExternal(WispUpdateSource.releasePageUrl);
    if (!mounted) return;
    if (!result.opened) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(result.message ?? '没能打开下载页面'),
          duration: const Duration(seconds: 6),
        ));
    }
  }

  /// 下载入口列表：官方源 + 加速镜像，与检查结果无关恒常显示。
  List<Widget> _downloadSection(BuildContext context, WispUpdateInfo? info) {
    final List<(String, String)> entries =
        info?.downloadEntries ?? _fallbackEntries();
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Row(
          children: <Widget>[
            Text(
              '手动下载',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (info != null) ...<Widget>[
              const SizedBox(width: 8),
              // 告诉用户这台机器会拿到什么包——各平台产物格式不同，
              // 只给一个链接容易被下错。
              Text(
                info.platformAssetLabel,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      for (final (String, String) entry in entries)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            entry.$1.startsWith('官方') ? Icons.verified_outlined : Icons.bolt_rounded,
            size: 18,
            color: entry.$1.startsWith('官方')
                ? WispColors.teal
                : WispColors.secondaryText(context),
          ),
          title: Text(entry.$1, style: Theme.of(context).textTheme.bodyMedium),
          trailing: Icon(Icons.open_in_new_rounded,
              size: 16, color: WispColors.secondaryText(context)),
          onTap: () async {
            final bool official = entry.$1.startsWith('官方');
            final ExternalOpenResult result = await openExternal(entry.$2);
            if (!context.mounted) return;
            final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
            messenger.hideCurrentSnackBar();
            if (!result.opened) {
              // 打不开必须说清楚，否则用户只会觉得"这按钮没用"。
              messenger.showSnackBar(SnackBar(
                content: Text(result.message ?? '没能打开下载链接'),
                duration: const Duration(seconds: 6),
              ));
              return;
            }
            if (!official) {
              messenger.showSnackBar(const SnackBar(
                content: Text('已打开加速镜像（第三方服务，仅代理下载地址）'),
              ));
            }
          },
        ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '镜像站为第三方加速服务，只代理下载地址；下载源可在上方切换，所选镜像失败会自动退回官方源。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ];
  }

  /// 检查失败/未完成时的兜底入口：至少能给用户指到发布页。
  List<(String, String)> _fallbackEntries() => <(String, String)>[
        ('官方源 · GitHub', WispUpdateSource.releasePageUrl),
        for (final String prefix in WispUpdateSource.mirrors)
          ('加速镜像 · ${WispUpdateSource.mirrorLabel(prefix)}',
              '$prefix${WispUpdateSource.releasePageUrl}'),
      ];
}

/// 下载/安装结束后的结果块：一行结论 + 可选「安装」按钮。
///
/// 单独拆成 public widget 是为了能被直接测试——「仅下载完成之后必须能给
/// 一键安装」是用户明确提过的诉求，而触发它需要走完整条下载链路
/// （widget 测试里 HttpClient 会被拦截，跑不成真下载）。
class WispUpdateResultCard extends StatelessWidget {
  const WispUpdateResultCard({
    super.key,
    required this.failed,
    required this.message,
    required this.onDismiss,
    this.onInstall,
  });

  final bool failed;
  final String message;

  /// 非空时显示「安装」按钮（安装包已下好、且该平台支持自动安装）。
  final VoidCallback? onInstall;

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              failed
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              size: 18,
              color: failed ? WispColors.warning : WispColors.success,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            if (onInstall != null) ...<Widget>[
              FilledButton(onPressed: onInstall, child: const Text('安装')),
              const SizedBox(width: 8),
            ],
            TextButton(
              onPressed: onDismiss,
              child: Text(failed ? '重试' : '关闭提示'),
            ),
          ],
        ),
      ],
    );
  }
}
