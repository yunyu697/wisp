import 'package:flutter/material.dart';

import '../../core/release_notes.dart';
import '../../core/utils/external.dart';
import '../../core/design/app_colors.dart';
import '../../services/update_service.dart';

/// 「检查更新」弹层：打开即发起检查，无论成败都列出下载入口
/// （官方源 + 加速镜像），检查失败也能手动取最新版。
///
/// [checkOverride] 供测试注入：null 走真实网络检查。
/// [onChecked] 在一次检查结束后回调（无论成败），
/// 用于刷新自动检查的时间戳，避免刚手动查完又被自动检查重复请求。
class UpdateSheet extends StatefulWidget {
  const UpdateSheet({super.key, this.checkOverride, this.onChecked});

  final Future<WispUpdateInfo?> Function()? checkOverride;
  final VoidCallback? onChecked;

  @override
  State<UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<UpdateSheet> {
  late Future<WispUpdateInfo?> _future;

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
        constraints: const BoxConstraints(maxHeight: 560),
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
                '当前 v${WispReleaseNotes.currentVersion}',
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
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        status,
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
        WispUpdateService.isNewer(info.latestVersion, WispReleaseNotes.currentVersion);
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
              '下载最新版',
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
          '镜像站为第三方加速服务，只代理下载地址；安装前请核对发布说明。',
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
