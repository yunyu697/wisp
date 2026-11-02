import 'dart:convert';

/// 设备类型，只影响图标，不参与协议逻辑。
enum DeviceKind {
  mobile,
  desktop,
  web,
  headless,
  server,
  unknown;

  String get wire => name;

  static DeviceKind parse(String? value) {
    switch (value) {
      case 'mobile':
        return DeviceKind.mobile;
      case 'desktop':
        return DeviceKind.desktop;
      case 'web':
        return DeviceKind.web;
      case 'headless':
        return DeviceKind.headless;
      case 'server':
        return DeviceKind.server;
      default:
        return DeviceKind.unknown;
    }
  }
}

/// 局域网里发现的一台设备。
class WispDevice {
  WispDevice({
    required this.alias,
    required this.ip,
    required this.fingerprint,
    this.version = '2.2',
    this.deviceModel,
    this.kind = DeviceKind.unknown,
    this.port = 53317,
    this.https = true,
    this.download = false,
    this.username = '',
    this.messageCapable = false,
    this.lastSeen,
  });

  final String alias;
  final String ip;
  final String fingerprint;
  final String version;
  final String? deviceModel;
  final DeviceKind kind;
  final int port;
  final bool https;
  final bool download;

  /// 对方的识别用户名（扩展字段，官方客户端不会带）。
  final String username;

  /// 对端是否支持文本消息（Wisp 扩展，见 [WispProtocol.messagePath]）。
  ///
  /// 官方 LocalSend 的报文里没有这个字段，解析出来就是 false ——
  /// 界面据此把「发消息」入口关掉，而不是让用户点了之后撞一个 404。
  final bool messageCapable;

  DateTime? lastSeen;

  /// 稳定的唯一键：指纹优先，没有指纹时退回 IP。
  String get key => fingerprint.isNotEmpty ? fingerprint : ip;

  String get baseUrl => '${https ? 'https' : 'http'}://$ip:$port';

  String get shortFingerprint =>
      fingerprint.length <= 8 ? fingerprint : fingerprint.substring(0, 8).toUpperCase();

  String get modelLabel {
    if (deviceModel != null && deviceModel!.isNotEmpty) return deviceModel!;
    switch (kind) {
      case DeviceKind.mobile:
        return '移动设备';
      case DeviceKind.desktop:
        return '桌面设备';
      case DeviceKind.web:
        return '浏览器';
      case DeviceKind.headless:
        return '命令行';
      case DeviceKind.server:
        return '服务器';
      case DeviceKind.unknown:
        return '未知设备';
    }
  }

  WispDevice copyWith({String? alias, int? port, DateTime? lastSeen}) => WispDevice(
        alias: alias ?? this.alias,
        ip: ip,
        fingerprint: fingerprint,
        version: version,
        deviceModel: deviceModel,
        kind: kind,
        port: port ?? this.port,
        https: https,
        download: download,
        username: username,
        messageCapable: messageCapable,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'alias': alias,
        'version': version,
        'deviceModel': deviceModel,
        'deviceType': kind.wire,
        'fingerprint': fingerprint,
        'port': port,
        'protocol': https ? 'https' : 'http',
        'download': download,
        if (username.isNotEmpty) 'username': username,
        // 只在对端支持时写出去：给官方客户端回 register 应答时多一个
        // 它不认识的字段是无害的，但少一个字段更省事，也更好对照抓包。
        if (messageCapable) 'message': true,
      };

  factory WispDevice.fromJson(Map<String, dynamic> json, {required String ip}) => WispDevice(
        alias: (json['alias'] as String?)?.trim().isNotEmpty == true
            ? json['alias'] as String
            : '未命名设备',
        ip: ip,
        fingerprint: (json['fingerprint'] as String?) ?? '',
        version: (json['version'] as String?) ?? '2.2',
        deviceModel: json['deviceModel'] as String?,
        kind: DeviceKind.parse(json['deviceType'] as String?),
        port: (json['port'] as num?)?.toInt() ?? 53317,
        https: (json['protocol'] as String?) != 'http',
        download: (json['download'] as bool?) ?? false,
        username: (json['username'] as String?) ?? '',
        messageCapable: (json['message'] as bool?) ?? false,
        lastSeen: DateTime.now(),
      );

  static WispDevice? tryParse(String raw, String ip) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return WispDevice.fromJson(decoded, ip: ip);
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}
