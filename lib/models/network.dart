import 'dart:io';

/// 发现方式。
///
/// 组播快但会被路由器隔离，扫描慢但穿透性好。默认两种一起用。
enum DiscoveryMode {
  auto,
  multicast,
  scan;

  String get label => switch (this) {
        DiscoveryMode.auto => '自动（组播 + 扫描）',
        DiscoveryMode.multicast => '仅组播',
        DiscoveryMode.scan => '仅扫描',
      };

  String get hint => switch (this) {
        DiscoveryMode.auto => '两条路并行，谁先发现用谁',
        DiscoveryMode.multicast => '秒级发现，路由器开了组播隔离时会失效',
        DiscoveryMode.scan => '逐个扫描网段，慢但能穿过组播隔离',
      };

  bool get multicastEnabled => this != DiscoveryMode.scan;

  bool get scanEnabled => this != DiscoveryMode.multicast;

  static DiscoveryMode parse(String? value) => DiscoveryMode.values.firstWhere(
        (DiscoveryMode m) => m.name == value,
        orElse: () => DiscoveryMode.auto,
      );
}

/// 本机的一块网卡。
class NetworkInterfaceInfo {
  const NetworkInterfaceInfo({
    required this.name,
    required this.address,
    required this.isVirtual,
    this.isDefault = false,
  });

  /// 系统给的网卡名，例如「Wi-Fi」「以太网」。
  final String name;

  /// 该网卡的 IPv4 地址。
  final String address;

  /// 虚拟网卡（VPN、虚拟机、WSL 之类），通常不该拿来发组播。
  final bool isVirtual;

  /// 是否为当前使用的默认网卡。
  final bool isDefault;

  String get display => '$name · $address';

  /// 用来在设置里持久化的稳定标识。
  String get id => '$name|$address';

  static bool looksVirtual(String name) {
    final String lower = name.toLowerCase();
    return lower.contains('vpn') ||
        lower.contains('virtual') ||
        lower.contains('vmware') ||
        lower.contains('virtualbox') ||
        lower.contains('hyper-v') ||
        lower.contains('loopback') ||
        lower.contains('tap') ||
        lower.contains('tailscale') ||
        lower.contains('zerotier');
  }

  /// 列出所有可用的 IPv4 网卡，按「物理 → 虚拟」排序。
  static Future<List<NetworkInterfaceInfo>> list() async {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );

    final List<NetworkInterfaceInfo> result = <NetworkInterfaceInfo>[];
    for (final NetworkInterface interface in interfaces) {
      for (final InternetAddress address in interface.addresses) {
        if (address.isLoopback) continue;
        final String ip = address.address;
        if (!ip.startsWith('192.168.') && !ip.startsWith('10.') && !ip.startsWith('172.')) {
          continue;
        }
        result.add(
          NetworkInterfaceInfo(
            name: interface.name,
            address: ip,
            isVirtual: looksVirtual(interface.name),
            isDefault: looksDefault(interface.name),
          ),
        );
      }
    }

    // 默认（无线/有线）网卡排前面，物理网卡其次，虚拟网卡最后。
    result.sort((NetworkInterfaceInfo a, NetworkInterfaceInfo b) {
      if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
      if (a.isVirtual != b.isVirtual) return a.isVirtual ? 1 : -1;
      return a.address.compareTo(b.address);
    });
    return result;
  }

  /// 猜测默认出口网卡：常见的无线/有线名字优先。
  static bool looksDefault(String name) {
    final String lower = name.toLowerCase();
    return lower.contains('wi-fi') ||
        lower.contains('wifi') ||
        lower.contains('wireless') ||
        lower.contains('无线') ||
        lower.contains('以太网') ||
        lower.contains('ethernet');
  }
}
