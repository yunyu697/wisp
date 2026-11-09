import 'dart:io';

import 'desktop_service.dart';

/// 开机启动在**系统里**的真实状态。
///
/// [supported] 为 false 时，设置页必须把这个开关藏起来，而不是显示一个
/// 点了没反应、或者显示"已开启"却根本不会启动的东西。
class LaunchAtLoginState {
  const LaunchAtLoginState({required this.supported, required this.enabled});

  static const LaunchAtLoginState unsupported =
      LaunchAtLoginState(supported: false, enabled: false);

  final bool supported;
  final bool enabled;
}

/// 登录时自动运行 Wisp。
///
/// 三个平台用的机制完全不同，但接口只有两个：[status] 和 [set]：
///
/// * Windows：`HKCU\...\CurrentVersion\Run` 注册表项（原生 C++ 实现）
/// * macOS：`SMAppService`，旧系统回退到 LaunchAgent（原生 Swift 实现）
/// * Linux：`~/.config/autostart/wisp.desktop`（纯 Dart，见下）
/// * Android / iOS：不支持
///
/// **状态一律回查系统**，不存本地设置。用户很可能直接在系统设置里关掉
/// 登录项，本地记着"开"就变成了一个骗人的开关。切换后也要再查一次，
/// 而不是相信"写成功了"。
class LaunchAtLogin {
  const LaunchAtLogin._();

  static const String _desktopEntryName = 'wisp.desktop';

  static String? _configDirOverride;
  static String? _executableOverride;

  /// 仅供测试：Linux 分支在 Windows/macOS 测试机上也要能跑，所以把
  /// XDG 目录和可执行路径做成可注入的。
  static void debugSetLinuxEnvironment({String? configDir, String? executable}) {
    _configDirOverride = configDir;
    _executableOverride = executable;
  }

  static void debugReset() {
    _configDirOverride = null;
    _executableOverride = null;
  }

  static Future<LaunchAtLoginState> status() async {
    switch (DesktopService.platform) {
      case DesktopPlatform.linux:
        if (_configDir().isEmpty) return LaunchAtLoginState.unsupported;
        return LaunchAtLoginState(
            supported: true, enabled: _linuxEnabled());
      case DesktopPlatform.windows:
      case DesktopPlatform.macos:
        final Map<String, Object?>? raw =
            await DesktopService.launchAtLoginStatus();
        if (raw == null) return LaunchAtLoginState.unsupported;
        return LaunchAtLoginState(
          supported: raw['supported'] == true,
          enabled: raw['enabled'] == true,
        );
      case DesktopPlatform.mobile:
        return LaunchAtLoginState.unsupported;
    }
  }

  /// 返回 false 表示没生效（写失败、平台不支持，或回查发现状态没变）。
  static Future<bool> set(bool enabled) async {
    switch (DesktopService.platform) {
      case DesktopPlatform.linux:
        return _linuxSet(enabled);
      case DesktopPlatform.windows:
      case DesktopPlatform.macos:
        return DesktopService.setLaunchAtLogin(enabled);
      case DesktopPlatform.mobile:
        return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Linux：XDG Autostart
  // ---------------------------------------------------------------------------

  /// autostart 规范只要求往这个目录放一个 .desktop 文件，不需要碰 runner 的
  /// C 代码——这也是这一端能做成纯 Dart、能被单元测试覆盖的原因。
  static String _configDir() {
    final String? override = _configDirOverride;
    if (override != null) return override;
    final String? xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    final String home = Platform.environment['HOME'] ?? '';
    return home.isEmpty ? '' : '$home/.config';
  }

  /// 要写进 `Exec=` 的路径。
  ///
  /// **AppImage 是个坑**：它每次运行都把自己挂到 `/tmp/.mount_XXXX`，
  /// `Platform.resolvedExecutable` 指向那个临时目录，写进 autostart 下次开机
  /// 必然失效。AppImage 启动时会把原始 .AppImage 的绝对路径放进 `APPIMAGE`
  /// 环境变量，优先用它。deb/rpm/tar.gz 安装则直接用可执行文件路径。
  static String _executable() {
    final String? override = _executableOverride;
    if (override != null) return override;
    final String? appimage = Platform.environment['APPIMAGE'];
    if (appimage != null && appimage.isNotEmpty) return appimage;
    return Platform.resolvedExecutable;
  }

  static File get _desktopFile =>
      File('${_configDir()}/autostart/$_desktopEntryName');

  static bool _linuxEnabled() {
    final File file = _desktopFile;
    if (!file.existsSync()) return false;
    try {
      final String text = file.readAsStringSync();
      // 系统设置里关掉登录项时，桌面环境会在文件里写这两行，文件本身还在。
      if (RegExp(r'^\s*Hidden\s*=\s*true', multiLine: true).hasMatch(text)) {
        return false;
      }
      if (RegExp(r'^\s*X-GNOME-Autostart-enabled\s*=\s*false', multiLine: true)
          .hasMatch(text)) {
        return false;
      }
      // 只认指向当前这份安装的条目：另一份 Wisp 留下的文件不该让开关
      // 显示"已开启"，否则用户关不掉一个自己根本没开过的东西。
      return text.contains(_executable());
    } on Object {
      return false;
    }
  }

  static bool _linuxSet(bool enabled) {
    if (_configDir().isEmpty) return false;
    final File file = _desktopFile;
    try {
      if (!enabled) {
        if (file.existsSync()) file.deleteSync();
        return true;
      }
      final String exec = _executable();
      if (exec.isEmpty) return false;
      file.parent.createSync(recursive: true);
      // 路径带空格时用双引号包住（desktop Exec 字段允许 quoted string）。
      file.writeAsStringSync(
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Version=1.0\n'
        'Name=Wisp\n'
        'Comment=Wisp local network file transfer\n'
        'Exec="$exec"\n'
        'Terminal=false\n'
        'X-GNOME-Autostart-enabled=true\n'
        'StartupWMClass=wisp\n',
      );
      return true;
    } on Object {
      return false;
    }
  }
}
