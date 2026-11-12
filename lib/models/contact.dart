import 'device.dart';

/// 联系人的留存状态。
///
/// 「临时」只占会话列表底部一个折叠区、不占联系人位、不计未读；
/// 「保留」是用户明确说过的"这台我常联系"，离线、换 Wi-Fi 都还在；
/// 「归档」只是移出主列表，**记录一条都不删**，搜索仍能找回。
enum ContactState { temporary, kept, archived }

/// 按 fingerprint 持久化的联系人。
///
/// 和 [WispDevice] 的区别：device 是「这一刻在线的一条发现记录」，60 秒
/// TTL 一到就消失；Contact 是「这台设备是谁」，ip / port / alias / 在线状态
/// 都只是它的可变属性。换局域网后设备重新出现，靠 [id] 挂回同一段聊天记录。
class Contact {
  Contact({
    required this.id,
    required this.alias,
    required this.kind,
    this.state = ContactState.temporary,
    this.pinned = false,
    List<String>? knownIps,
    DateTime? firstSeen,
    DateTime? lastActive,
  })  : knownIps = knownIps ?? <String>[],
        firstSeen = firstSeen ?? DateTime.now(),
        lastActive = lastActive ?? DateTime.now();

  /// 稳定主键：对端证书 fingerprint。**永不退化成 IP**。
  final String id;

  String alias;
  DeviceKind kind;
  ContactState state;
  bool pinned;

  /// 曾用过的网络地址，只用于展示「曾用网络 N 个」，不参与身份判定。
  final List<String> knownIps;

  DateTime firstSeen;
  DateTime lastActive;

  bool get isTemporary => state == ContactState.temporary;
  bool get isKept => state == ContactState.kept;
  bool get isArchived => state == ContactState.archived;

  String get shortId =>
      id.length <= 8 ? id.toUpperCase() : '${id.substring(0, 8).toUpperCase()}…';

  String get stateLabel {
    switch (state) {
      case ContactState.temporary:
        return '临时会话';
      case ContactState.kept:
        return '保留的联系人';
      case ContactState.archived:
        return '已归档';
    }
  }

  /// 记录一次出现：刷新别名、类型、活动时间和当前地址。
  /// 别名被对方改了就跟着更新，但**绝不**用别名反过来认人。
  void noteSeen(WispDevice device, DateTime now) {
    alias = device.alias;
    kind = device.kind;
    lastActive = now;
    noteIp(device.ip);
  }

  void noteIp(String ip) {
    if (ip.trim().isEmpty) return;
    if (knownIps.contains(ip)) {
      knownIps
        ..remove(ip)
        ..insert(0, ip);
    } else {
      knownIps.insert(0, ip);
    }
    // 曾用网络只是展示用的线索，留最近 6 个足够，避免无限增长。
    if (knownIps.length > 6) knownIps.removeRange(6, knownIps.length);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'alias': alias,
        'kind': kind.name,
        'state': state.name,
        if (pinned) 'pinned': true,
        'knownIps': knownIps,
        'firstSeen': firstSeen.toIso8601String(),
        'lastActive': lastActive.toIso8601String(),
      };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        id: (json['id'] as String?) ?? '',
        alias: (json['alias'] as String?) ?? '未知设备',
        kind: DeviceKind.parse(json['kind'] as String?),
        state: ContactState.values.firstWhere(
          (ContactState s) => s.name == json['state'],
          orElse: () => ContactState.temporary,
        ),
        pinned: json['pinned'] == true,
        knownIps: (json['knownIps'] as List<dynamic>? ?? <dynamic>[])
            .map((dynamic e) => e.toString())
            .toList(),
        firstSeen:
            DateTime.tryParse((json['firstSeen'] as String?) ?? '') ?? DateTime.now(),
        lastActive:
            DateTime.tryParse((json['lastActive'] as String?) ?? '') ?? DateTime.now(),
      );
}
