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

  /// 发布产物里的清单：由 CI 在发版时生成并附到 Release 上，**带各平台 sha256**。
  /// `releases/latest/download/<asset>` 永远指向最新一版，不用跟着版本号改。
  static const String releaseManifestUrl =
      'https://github.com/$repoOwner/$repoName/releases/latest/download/update.json';

  /// 仓库根目录的清单：手工维护，作为发布产物缺失时的兜底（没有 sha256）。
  static const String repoManifestUrl =
      'https://raw.githubusercontent.com/$repoOwner/$repoName/main/update.json';

  /// 默认清单地址（官方源）。镜像探测按 [mirrors] 逐个加前缀重试。
  static const String manifestUrl = releaseManifestUrl;

  /// GitHub 加速镜像（前缀代理形式）。失效就删掉，有新的往里加；
  /// 顺序即「检查更新」时的重试顺序，也决定下载列表的排列顺序。
  ///
  /// 2026-10-31 实测：ghfast.top / gh-proxy.com / ghproxy.net 可用（HTTP 200），
  /// gh.llkk.cc 已失效（连接不通），已移除。
  static const List<String> mirrors = <String>[
    'https://ghfast.top/',
    'https://gh-proxy.com/',
    'https://ghproxy.net/',
  ];

  /// 镜像的展示名（去掉协议与斜杠，列表里显示用）。
  static String mirrorLabel(String prefix) =>
      prefix.replaceFirst(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/+$'), '');

  /// 可手动选择的下载源：官方直连在前，其余按 [mirrors] 顺序。
  ///
  /// 展示名刻意与「手动下载」列表里的 `官方源 · GitHub` / `加速镜像 · xxx`
  /// 不同：那两行是**发布页链接**，这里是**下载安装包时走哪条线路**，
  /// 混用名字会让人以为是同一个开关。
  ///
  /// 做成 static final（只算一次）：DropdownButton 用值相等匹配当前项，
  /// 每次重建都给出新实例会让它选不中、直接抛断言。
  static final List<WispUpdateSourceOption> downloadOptions =
      <WispUpdateSourceOption>[
    const WispUpdateSourceOption(label: '官方源（推荐）', prefix: null),
    for (final String prefix in mirrors)
      WispUpdateSourceOption(label: mirrorLabel(prefix), prefix: prefix),
  ];

  static String get releasePageUrl =>
      'https://github.com/$repoOwner/$repoName/releases/latest';
}

/// 一个可选下载源。`prefix == null` 表示官方直连（不经过任何第三方）。
class WispUpdateSourceOption {
  const WispUpdateSourceOption({required this.label, required this.prefix});

  /// 下拉列表里的展示名。
  final String label;

  /// 镜像前缀（`https://ghfast.top/` 这种）；官方源为 null。
  final String? prefix;

  bool get isOfficial => prefix == null;

  /// 把原始地址套成本源上的地址。
  String apply(String url) => prefix == null ? url : '$prefix$url';

  @override
  bool operator ==(Object other) =>
      other is WispUpdateSourceOption && other.prefix == prefix;

  @override
  int get hashCode => prefix.hashCode;
}

/// 一次成功的检查结果。
class WispUpdateInfo {
  const WispUpdateInfo({
    required this.latestVersion,
    this.notes,
    this.downloadUrl,
    this.downloads = const <String, String>{},
    this.sha256 = const <String, String>{},
  });

  factory WispUpdateInfo.fromJson(Map<String, dynamic> json) {
    final String? notes = (json['notes'] as String?)?.trim();
    final String? downloadUrl = (json['downloadUrl'] as String?)?.trim();
    // 分平台产物表：{"windows": "...exe", "macos": "...dmg", ...}
    final Map<String, String> downloads = <String, String>{};
    final Object? rawDownloads = json['downloads'];
    if (rawDownloads is Map) {
      rawDownloads.forEach((Object? key, Object? value) {
        if (key is String && value is String) {
          final String trimmed = value.trim();
          if (trimmed.isNotEmpty) downloads[key] = trimmed;
        }
      });
    }
    // 各平台安装包的 sha256：{"windows": "...", "macos": "...", ...}
    // 下载完必须比对，否则一键更新等于「从第三方镜像拿个 exe 就提权运行」。
    final Map<String, String> hashes = <String, String>{};
    final Object? rawHashes = json['sha256'];
    if (rawHashes is Map) {
      rawHashes.forEach((Object? key, Object? value) {
        if (key is String && value is String) {
          final String trimmed = value.trim().toLowerCase();
          if (trimmed.isNotEmpty) hashes[key] = trimmed;
        }
      });
    }
    return WispUpdateInfo(
      latestVersion: (json['version'] as String?) ?? '',
      notes: notes == null || notes.isEmpty ? null : notes,
      downloadUrl: downloadUrl == null || downloadUrl.isEmpty ? null : downloadUrl,
      downloads: downloads,
      sha256: hashes,
    );
  }

  final String latestVersion;

  /// 更新说明（可空）。
  final String? notes;

  /// 最新版安装包直链（可空，缺省用发布页）。
  final String? downloadUrl;

  /// 分平台产物直链：key 为 windows / macos / linux / android。
  final Map<String, String> downloads;

  /// 分平台安装包的 sha256（小写十六进制）。清单没给时为空。
  final Map<String, String> sha256;

  /// 当前平台安装包的期望摘要；清单没提供时为 null。
  ///
  /// 为 null 意味着**无法校验**——自动安装会因此被拒绝，只允许手动下载。
  String? get expectedSha256 {
    final String? value = sha256[platformKey];
    return value == null || value.isEmpty ? null : value;
  }

  /// 当前平台对应的下载直链。没有就退回通用 [downloadUrl]，再退回发布页。
  String get primaryUrl {
    final String? platformUrl = downloads[platformKey];
    if (platformUrl != null && platformUrl.isNotEmpty) return platformUrl;
    return downloadUrl ?? WispUpdateSource.releasePageUrl;
  }

  /// 当前平台的产物名，用于界面提示（例：Windows 安装包）。
  String get platformAssetLabel {
    switch (platformKey) {
      case 'windows':
        return 'Windows 安装包';
      case 'macos':
        return 'macOS 镜像';
      case 'linux':
        return 'Linux 安装包';
      case 'android':
        return 'Android 安装包';
      default:
        return '安装包';
    }
  }

  /// 官方 + 各镜像的下载入口，设置页按这个顺序展示。
  List<(String, String)> get downloadEntries => <(String, String)>[
        ('官方源 · GitHub', primaryUrl),
        for (final String prefix in WispUpdateSource.mirrors)
          ('加速镜像 · ${WispUpdateSource.mirrorLabel(prefix)}', '$prefix$primaryUrl'),
      ];
}

/// 当前运行平台的产物键（与 update.json 的 `downloads` 对应）。
String get platformKey {
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isAndroid) return 'android';
  return 'other';
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
          // 先试发布产物（带 sha256），再试仓库根目录（手工维护的兜底），
          // 最后按镜像顺序重试发布产物——镜像只代理发布地址，不代理 raw。
          WispUpdateSource.releaseManifestUrl,
          WispUpdateSource.repoManifestUrl,
          for (final String prefix in WispUpdateSource.mirrors)
            '$prefix${WispUpdateSource.releaseManifestUrl}',
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
