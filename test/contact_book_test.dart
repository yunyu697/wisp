import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/models/contact.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/services/contact_book.dart';

WispDevice _device(String fingerprint, String ip, {String alias = '客厅的 Mac mini'}) =>
    WispDevice(
      alias: alias,
      ip: ip,
      fingerprint: fingerprint,
      kind: DeviceKind.desktop,
    );

void main() {
  final DateTime now = DateTime(2026, 11, 12);

  test('换局域网仍是同一台设备：按 fingerprint 合并，不按 IP / 别名', () {
    final List<Contact> contacts = <Contact>[];
    expect(
      ContactBook.upsert(contacts, _device('fp-A', '192.168.1.24'), now: now),
      isTrue,
    );
    expect(
      ContactBook.upsert(
        contacts,
        _device('fp-A', '10.0.0.7', alias: '改过名字的 Mac'),
        now: now.add(const Duration(minutes: 5)),
      ),
      isFalse,
      reason: '同一 fingerprint 不该新增联系人，哪怕 IP 和别名都变了',
    );
    expect(contacts.length, 1);
    expect(contacts.first.id, 'fp-A');
    expect(contacts.first.alias, '改过名字的 Mac');
    expect(contacts.first.knownIps, <String>['10.0.0.7', '192.168.1.24']);
    expect(contacts.first.lastActive, now.add(const Duration(minutes: 5)));
  });

  test('不同 fingerprint 绝不自动合并', () {
    final List<Contact> contacts = <Contact>[];
    ContactBook.upsert(contacts, _device('fp-A', '192.168.1.24'), now: now);
    ContactBook.upsert(
      contacts,
      _device('fp-B', '192.168.1.24', alias: '客厅的 Mac mini'),
      now: now,
    );
    expect(contacts.length, 2,
        reason: '别名和 IP 都一样也不能自动合并，否则 A 的文件会挂到 B 名下');
  });

  test('没有 fingerprint 的老设备不入簿，只走临时会话', () {
    final List<Contact> contacts = <Contact>[];
    expect(ContactBook.upsert(contacts, _device('', '192.168.1.31'), now: now), isFalse);
    expect(ContactBook.upsert(contacts, _device('   ', '192.168.1.31'), now: now), isFalse);
    expect(contacts, isEmpty);
  });

  test('30 天无活动的临时会话只归档，记录一条都不删', () {
    final List<Contact> contacts = <Contact>[];
    ContactBook.upsert(contacts, _device('fp-A', '192.168.1.24'), now: now);
    final Contact kept = ContactBook.byId(contacts, 'fp-A')!;
    kept.state = ContactState.kept;
    ContactBook.upsert(contacts, _device('fp-B', '10.0.0.8'), now: now);

    final DateTime later = now.add(const Duration(days: 31));
    final int changed = ContactBook.archiveIdle(contacts, later);

    expect(changed, 1);
    expect(contacts.length, 2, reason: '归档只改状态，不能删记录');
    expect(ContactBook.byId(contacts, 'fp-B')!.isArchived, isTrue);
    expect(
      ContactBook.byId(contacts, 'fp-A')!.isKept,
      isTrue,
      reason: '用户手动保留的联系人永不自动归档',
    );
  });

  test('归档过的设备重新出现会回到列表，但仍是同一个身份', () {
    final List<Contact> contacts = <Contact>[];
    ContactBook.upsert(contacts, _device('fp-A', '192.168.1.24'), now: now);
    ContactBook.byId(contacts, 'fp-A')!.state = ContactState.archived;
    ContactBook.upsert(contacts, _device('fp-A', '172.16.4.19'), now: now);
    expect(contacts.length, 1);
    expect(contacts.first.isTemporary, isTrue);
    expect(contacts.first.knownIps.first, '172.16.4.19');
  });

  test('曾用网络去重且只留最近 6 个', () {
    final List<Contact> contacts = <Contact>[];
    ContactBook.upsert(contacts, _device('fp-A', '10.0.0.1'), now: now);
    for (int i = 2; i <= 8; i++) {
      ContactBook.upsert(contacts, _device('fp-A', '10.0.0.$i'), now: now);
    }
    ContactBook.upsert(contacts, _device('fp-A', '10.0.0.3'), now: now);
    final List<String> ips = contacts.first.knownIps;
    expect(ips.length, 6);
    expect(ips.first, '10.0.0.3');
    expect(ips.toSet().length, 6, reason: '重复地址不能占两个位置');
  });

  test('Contact JSON 往返保留状态与时间戳', () {
    final Contact original = Contact(
      id: 'fp-A',
      alias: '书房 Windows',
      kind: DeviceKind.desktop,
      state: ContactState.kept,
      pinned: true,
      knownIps: <String>['192.168.1.31'],
      firstSeen: now,
      lastActive: now.add(const Duration(days: 2)),
    );
    final Contact restored = Contact.fromJson(original.toJson());
    expect(restored.id, 'fp-A');
    expect(restored.state, ContactState.kept);
    expect(restored.pinned, isTrue);
    expect(restored.kind, DeviceKind.desktop);
    expect(restored.shortId, 'FP-A');
    expect(restored.knownIps, <String>['192.168.1.31']);
    expect(restored.firstSeen, now);
  });
}
