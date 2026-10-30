/// 检查更新：从发布仓库读一份 `update.json` 清单，和当前版本比一比。
///
/// 清单格式（放在仓库根目录，GitHub Raw 即可直读）：
/// ```json
/// {
///   "version": "1.0.13",
///   "notes": "本次更新内容…",
///   "downloadUrl": "https://github.com/<owner>/<repo>/releases/download/v1.0.13/wisp-windows-x64-1.0.13.zip"
/// }
/// ```
/// `downloadUrl` 缺省时退回「发布页」链接。
///
/// **镜像策略**：GitHub Raw 与 Releases 下载都支持「前缀代理」，即
/// `https://ghfast.top/https://github.com/...` 这种把完整原地址接在镜像域名后面的
/// 形式。清单请求按 官方 → 镜像 逐个试，下载列表则把官方地址和每个镜像并列展示，
/// 由用户挑顺手的（自动选镜像下载有供应链风险，让用户自己决定）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class WispUpdateSource {
  const WispUpdateSource._();

  /// 发布仓库。仓库建好后改这两行，清单与下载地址都会跟着走。
  static const String repoOwner = 'yunyu697';
  static const String repoName = 'wisp';

  /// 更新清单地址（官方源）。镜像探测按 [mirrors] 逐个加前缀重试。
  static const String manifestUrl =
      'https://raw.githubusercontent.com/$repoOwner/$repoName/main/update.json';

  /// GitHub 加速镜像（前缀代理形式）。失效就删掉，有新的往里加；
  /// 顺序即「检查更新」时的重试顺序，也决定下载列表的排列顺序。
  static const List<String> mirrors = <String>[
    'https://ghfast.top/',
    'https://gh-proxy.com/',
    'https://ghproxy.net/',
    'https://gh.llkk.cc/',
  ];

  /// 镜像的展示名（去掉协议与斜杠，列表里显示用）。
  static String mirrorLabel(String prefix) =>
      prefix.replaceFirst(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/+$'), '');

  static String get releasePageUrl =>
      'https://github.com/$repoOwner/$repoName/releases/latest';
}

/// 一次成功的检查结果。
class WispUpdateInfo {
  const WispUpdateInfo({
    required this.latestVersion,
    this.notes,
    this.downloadUrl,
  });

  factory WispUpdateInfo.fromJson(Map<String, dynamic> json) {
    final String? notes = (json['notes'] as String?)?.trim();
    final String? downloadUrl = (json['downloadUrl'] as String?)?.trim();
    return WispUpdateInfo(
      latestVersion: (json['version'] as String?) ?? '',
      notes: notes == null || notes.isEmpty ? null : notes,
      downloadUrl: downloadUrl == null || downloadUrl.isEmpty ? null : downloadUrl,
    );
  }

  final String latestVersion;

  /// 更新说明（可空）。
  final String? notes;

  /// 最新版安装包直链（可空，缺省用发布页）。
  final String? downloadUrl;

  /// 下载入口：有直链用直链，没有就退回发布页。
  String get primaryUrl => downloadUrl ?? WispUpdateSource.releasePageUrl;

  /// 官方 + 各镜像的下载入口，设置页按这个顺序展示。
  List<(String, String)> get downloadEntries => <(String, String)>[
        ('官方源 · GitHub', primaryUrl),
        for (final String prefix in WispUpdateSource.mirrors)
          ('加速镜像 · ${WispUpdateSource.mirrorLabel(prefix)}', '$prefix$primaryUrl'),
      ];
}

/// 自动检查更新的频率。落盘值 = 两次检查最少间隔的小时数：
/// 0 = 关闭（只手动查），1 = 每次启动都查，24/168 = 每天/每周最多查一次。
class WispUpdateCadence {
  const WispUpdateCadence._();

  static const int off = 0;
  static const int everyStartup = 1;
  static const int daily = 24;
  static const int weekly = 168;

  /// 默认频率：每天一次，不打扰也不错过。
  static const int defaultHours = daily;

  /// 设置页的选项与展示顺序。
  static const Map<String, int> options = <String, int>{
    '关闭': off,
    '每次启动': everyStartup,
    '每天一次': daily,
    '每周一次': weekly,
  };

  static String label(int hours) {
    for (final MapEntry<String, int> entry in options.entries) {
      if (entry.value == hours) return entry.key;
    }
    return '每天一次';
  }

  /// 现在到点了吗？[lastMs] / [nowMs] 是毫秒时间戳。
  ///
  /// 「每次启动」无视上次检查时间——它的语义就是"这轮启动查一次"；
  /// 其余按间隔比较，从没查过（lastMs = 0）视为到点。
  static bool isDue(int hours, int lastMs, int nowMs) {
    if (hours <= off) return false;
    if (hours == everyStartup) return true;
    if (lastMs <= 0) return true;
    return nowMs - lastMs >= hours * 3600000;
  }
}

class WispUpdateService {
  const WispUpdateService._();

  /// 官方源 + 全部镜像逐个试，任何一个成功即返回；全失败返回 null。
  ///
  /// [sources] 供测试注入本地地址；生产环境用默认的 官方+镜像 清单。
  static Future<WispUpdateInfo?> check({
    Duration timeout = const Duration(seconds: 8),
    List<String>? sources,
  }) async {
    final List<String> urls = sources ??
        <String>[
          WispUpdateSource.manifestUrl,
          for (final String prefix in WispUpdateSource.mirrors)
            '$prefix${WispUpdateSource.manifestUrl}',
        ];
    for (final String url in urls) {
      try {
        final WispUpdateInfo? info = await _fetchOne(url, timeout);
        if (info != null && info.latestVersion.isNotEmpty) return info;
      } catch (_) {
        // 换下一个源。单个源失败是常态，不在这里记日志刷屏。
      }
    }
    return null;
  }

  static Future<WispUpdateInfo?> _fetchOne(String url, Duration timeout) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final HttpClientRequest request =
          await client.getUrl(Uri.parse(url)).timeout(timeout);
      final HttpClientResponse response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      final String body =
          await response.transform(utf8.decoder).join().timeout(timeout);
      final dynamic decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      return WispUpdateInfo.fromJson(decoded);
    } finally {
      client.close(force: true);
    }
  }

  /// 语义化版本比较：负数 = a 更旧，0 = 相同，正数 = a 更新。
  /// 每段取前导数字（"13-beta" 按 13），段数不齐按 0 补。
  static int compareVersions(String a, String b) {
    final List<int> pa = _parse(a);
    final List<int> pb = _parse(b);
    final int len = pa.length > pb.length ? pa.length : pb.length;
    for (int i = 0; i < len; i++) {
      final int x = i < pa.length ? pa[i] : 0;
      final int y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  static final RegExp _leadingDigits = RegExp(r'^(\d+)');

  static List<int> _parse(String version) {
    final List<int> parts = <int>[];
    for (final String segment in version.trim().split('.')) {
      final RegExpMatch? m = _leadingDigits.firstMatch(segment.trim());
      parts.add(m == null ? 0 : int.parse(m.group(1)!));
    }
    return parts;
  }

  /// 是否有新版本（严格大于当前版本才提示）。
  static bool isNewer(String latest, String current) =>
      compareVersions(latest, current) > 0;
}
