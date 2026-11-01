import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import '../models/network.dart';
import 'update_service.dart';

/// 可持久化的用户偏好。不可变对象，改动一律 copyWith 后整体落盘。
@immutable
class WispSettings {
  const WispSettings({
    required this.alias,
    required this.fingerprint,
    this.visible = true,
    this.encryption = true,
    this.pinEnabled = false,
    this.pin = '',
    this.autoAccept = false,
    this.saveDirectory,
    this.themeMode = ThemeMode.system,
    this.deviceKind = DeviceKind.desktop,
    this.username = '',
    this.port = 53317,
    this.networkInterface,
    this.discoveryMode = DiscoveryMode.auto,
    this.scanIntervalSeconds = 30,
    this.minimizeToTray = true,
    this.silentStart = false,
    this.floatingBall = false,
    this.ballShowDelayMs = 300,
    this.ballPosX,
    this.ballPosY,
    this.ballSnapped = false,
    this.ballEdge = -1,
    this.installAsService = false,
    this.updateCheckHours = WispUpdateCadence.defaultHours,
    this.lastUpdateCheckMs = 0,
  });

  final String alias;
  final String fingerprint;
  final bool visible;
  final bool encryption;
  final bool pinEnabled;
  final String pin;
  final bool autoAccept;
  final String? saveDirectory;
  final ThemeMode themeMode;
  final DeviceKind deviceKind;

  /// 识别用户名。留空表示不设限，能发现局域网里所有设备；
  /// 填了之后只显示同名用户的设备。
  final String username;

  /// 监听端口。默认 53317，和官方 LocalSend 一致；
  /// 同机跑两个 LocalSend 时改成别的端口即可。
  final int port;

  /// 指定使用哪块网卡发组播（null = 自动选默认那块）。
  final String? networkInterface;

  /// 发现方式：组播、扫描，还是两者都用。
  final DiscoveryMode discoveryMode;

  /// 周期扫描的间隔秒数，0 表示关掉周期扫描（只在启动和手动触发时扫）。
  final int scanIntervalSeconds;

  /// 点关闭按钮时是否最小化到系统托盘。
  final bool minimizeToTray;

  /// 静默启动：启动时不显示主窗口，只在托盘（以及悬浮球，如果开了）里待着。
  ///
  /// 典型场景是开机自启——用户开机只是想让它在后台等着收文件，
  /// 不需要每次都被一个窗口挡住。
  final bool silentStart;

  /// 是否启用桌面悬浮球。启用后桌面上常驻一个软件图标圆球，
  /// 有传输请求时在它旁边弹出气泡。
  final bool floatingBall;

  /// 悬浮球收成把手后，鼠标悬停多久自动展开（毫秒，0 = 立即）。
  final int ballShowDelayMs;

  /// 悬浮球上次停留的位置（物理像素）。null 表示还没拖过，用默认右下角。
  final int? ballPosX;
  final int? ballPosY;

  /// 上次停留时是否吸附在屏幕边缘，及在哪条边（0 左 1 右 2 上 3 下）。
  final bool ballSnapped;
  final int ballEdge;

  /// 是否安装了 Windows 守护服务（防意外退出 + 开机自启）。
  /// 只作界面记忆，真实状态以服务管理器为准（启动时回查）。
  final bool installAsService;

  /// 自动检查更新的最小间隔小时数（见 [WispUpdateCadence]）。
  final int updateCheckHours;

  /// 上次自动检查的毫秒时间戳，0 = 从未检查过。手动检查也会刷新它。
  final int lastUpdateCheckMs;

  /// 是否设了识别用户名。
  bool get hasUsername => username.trim().isNotEmpty;

  WispSettings copyWith({
    String? alias,
    bool? visible,
    bool? encryption,
    bool? pinEnabled,
    String? pin,
    bool? autoAccept,
    String? saveDirectory,
    ThemeMode? themeMode,
    DeviceKind? deviceKind,
    String? username,
    int? port,
    String? networkInterface,
    bool clearNetworkInterface = false,
    DiscoveryMode? discoveryMode,
    int? scanIntervalSeconds,
    bool? minimizeToTray,
    bool? silentStart,
    bool? floatingBall,
    int? ballShowDelayMs,
    int? ballPosX,
    int? ballPosY,
    bool? ballSnapped,
    int? ballEdge,
    bool? installAsService,
    int? updateCheckHours,
    int? lastUpdateCheckMs,
  }) =>
      WispSettings(
        alias: alias ?? this.alias,
        fingerprint: fingerprint,
        visible: visible ?? this.visible,
        encryption: encryption ?? this.encryption,
        pinEnabled: pinEnabled ?? this.pinEnabled,
        pin: pin ?? this.pin,
        autoAccept: autoAccept ?? this.autoAccept,
        saveDirectory: saveDirectory ?? this.saveDirectory,
        themeMode: themeMode ?? this.themeMode,
        deviceKind: deviceKind ?? this.deviceKind,
        username: username ?? this.username,
        port: port ?? this.port,
        networkInterface:
            clearNetworkInterface ? null : (networkInterface ?? this.networkInterface),
        discoveryMode: discoveryMode ?? this.discoveryMode,
        scanIntervalSeconds: scanIntervalSeconds ?? this.scanIntervalSeconds,
        minimizeToTray: minimizeToTray ?? this.minimizeToTray,
        silentStart: silentStart ?? this.silentStart,
        floatingBall: floatingBall ?? this.floatingBall,
        ballShowDelayMs: ballShowDelayMs ?? this.ballShowDelayMs,
        ballPosX: ballPosX ?? this.ballPosX,
        ballPosY: ballPosY ?? this.ballPosY,
        ballSnapped: ballSnapped ?? this.ballSnapped,
        ballEdge: ballEdge ?? this.ballEdge,
        installAsService: installAsService ?? this.installAsService,
        updateCheckHours: updateCheckHours ?? this.updateCheckHours,
        lastUpdateCheckMs: lastUpdateCheckMs ?? this.lastUpdateCheckMs,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'alias': alias,
        'fingerprint': fingerprint,
        'visible': visible,
        'encryption': encryption,
        'pinEnabled': pinEnabled,
        'pin': pin,
        'autoAccept': autoAccept,
        'saveDirectory': saveDirectory,
        'themeMode': themeMode.name,
        'deviceKind': deviceKind.name,
        'username': username,
        'port': port,
        'networkInterface': networkInterface,
        'discoveryMode': discoveryMode.name,
        'scanIntervalSeconds': scanIntervalSeconds,
        'minimizeToTray': minimizeToTray,
        'silentStart': silentStart,
        'floatingBall': floatingBall,
        'ballShowDelayMs': ballShowDelayMs,
        'ballPosX': ballPosX,
        'ballPosY': ballPosY,
        'ballSnapped': ballSnapped,
        'ballEdge': ballEdge,
        'installAsService': installAsService,
        'updateCheckHours': updateCheckHours,
        'lastUpdateCheckMs': lastUpdateCheckMs,
      };

  factory WispSettings.fromJson(Map<String, dynamic> json) => WispSettings(
        alias: (json['alias'] as String?) ?? '我的设备',
        fingerprint: (json['fingerprint'] as String?) ?? '',
        visible: (json['visible'] as bool?) ?? true,
        encryption: (json['encryption'] as bool?) ?? true,
        pinEnabled: (json['pinEnabled'] as bool?) ?? false,
        pin: (json['pin'] as String?) ?? '',
        autoAccept: (json['autoAccept'] as bool?) ?? false,
        saveDirectory: json['saveDirectory'] as String?,
        themeMode: ThemeMode.values.firstWhere(
          (ThemeMode m) => m.name == json['themeMode'],
          orElse: () => ThemeMode.system,
        ),
        deviceKind: DeviceKind.parse(json['deviceKind'] as String?),
        username: (json['username'] as String?) ?? '',
        port: (json['port'] as num?)?.toInt() ?? 53317,
        networkInterface: json['networkInterface'] as String?,
        discoveryMode: DiscoveryMode.parse(json['discoveryMode'] as String?),
        scanIntervalSeconds: (json['scanIntervalSeconds'] as num?)?.toInt() ?? 30,
        minimizeToTray: (json['minimizeToTray'] as bool?) ?? true,
        silentStart: (json['silentStart'] as bool?) ?? false,
        floatingBall: (json['floatingBall'] as bool?) ?? false,
        ballShowDelayMs: (json['ballShowDelayMs'] as num?)?.toInt() ?? 300,
        ballPosX: (json['ballPosX'] as num?)?.toInt(),
        ballPosY: (json['ballPosY'] as num?)?.toInt(),
        ballSnapped: (json['ballSnapped'] as bool?) ?? false,
        ballEdge: (json['ballEdge'] as num?)?.toInt() ?? -1,
        installAsService: (json['installAsService'] as bool?) ?? false,
        updateCheckHours:
            (json['updateCheckHours'] as num?)?.toInt() ?? WispUpdateCadence.defaultHours,
        lastUpdateCheckMs: (json['lastUpdateCheckMs'] as num?)?.toInt() ?? 0,
      );

  static WispSettings defaults() => WispSettings(
        alias: _defaultAlias(),
        fingerprint: _randomFingerprint(),
        deviceKind: _guessDeviceKind(),
      );

  static String _defaultAlias() {
    final String model = _platformLabel();
    return '$model 上的 Wisp';
  }

  static String _platformLabel() {
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'PC';
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isLinux) return 'Linux';
    return '设备';
  }

  static DeviceKind _guessDeviceKind() {
    if (Platform.isAndroid || Platform.isIOS) return DeviceKind.mobile;
    return DeviceKind.desktop;
  }

  /// 32 位十六进制指纹。开启加密时，真实部署应换成证书 SHA-256。
  static String _randomFingerprint() {
    final Random random = Random.secure();
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 16; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

class SettingsService {
  static const String _key = 'wisp.settings.v1';

  Future<WispSettings> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null) {
      final WispSettings fresh = WispSettings.defaults();
      await save(fresh);
      return fresh;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return WispSettings.fromJson(decoded);
    } on FormatException {
      // 落盘数据损坏时不要崩，退回默认值。
    }
    return WispSettings.defaults();
  }

  Future<void> save(WispSettings settings) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(settings.toJson()));
  }
}
