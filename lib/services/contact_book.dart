import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/contact.dart';
import '../models/device.dart';

/// 联系人簿：按 fingerprint 持久化的身份层。
///
/// `AppState.devices` 是 60 秒 TTL 的在线表，离线即消失；这里存的是
/// 「见过谁」。换一个局域网之后设备重新出现，靠 [Contact.id] 挂回原来的
/// 会话，聊天记录不会按 IP 分裂。
///
/// 老设备没有 fingerprint 时**不入簿**：它们只开临时会话，不保证跨网络
/// 归并，避免把 A 的文件错挂到 B 名下。
class ContactBook {
  static const String _key = 'wisp.contacts.v1';

  /// 临时会话多久没有活动就归档。归档只移出主列表，记录不删。
  static const Duration archiveAfter = Duration(days: 30);

  Future<List<Contact>> load() async {
    final String? raw;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      raw = prefs.getString(_key);
    } on MissingPluginException {
      // 纯 widget / golden 测试没有平台插件；读不到就当空簿，别炸掉界面。
      return <Contact>[];
    }
    if (raw == null || raw.isEmpty) return <Contact>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) return <Contact>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(Contact.fromJson)
          .where((Contact c) => c.id.trim().isNotEmpty)
          .toList();
    } on FormatException {
      return <Contact>[];
    }
  }

  Future<void> save(List<Contact> contacts) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key, jsonEncode(contacts.map((Contact c) => c.toJson()).toList()));
    } on MissingPluginException {
      // 身份层落盘失败不能打断设备发现 / 文件传输这条主链路，
      // 下一次成功写入时会把当前内存里的全量联系人补上。
    }
  }

  /// 一次发现/一次往来都要调：刷新这台联系人的可变属性。
  /// 返回是否新增了联系人，方便调用方决定要不要落盘。
  static bool upsert(
    List<Contact> contacts,
    WispDevice device, {
    DateTime? now,
  }) {
    final String id = device.fingerprint.trim();
    if (id.isEmpty) return false;
    final DateTime stamp = now ?? DateTime.now();
    for (final Contact contact in contacts) {
      if (contact.id == id) {
        contact.noteSeen(device, stamp);
        // 归档过的设备重新出现就回到列表里，但记录一直都在。
        if (contact.isArchived) contact.state = ContactState.temporary;
        return false;
      }
    }
    contacts.add(Contact(
      id: id,
      alias: device.alias,
      kind: device.kind,
      firstSeen: stamp,
      lastActive: stamp,
    )..noteIp(device.ip));
    return true;
  }

  /// 启动巡检：只把「临时且 30 天没动静」的移进归档。
  /// 用户手动保留的联系人**永不**自动归档。
  static int archiveIdle(List<Contact> contacts, DateTime now) {
    int changed = 0;
    for (final Contact contact in contacts) {
      if (!contact.isTemporary) continue;
      if (now.difference(contact.lastActive) < archiveAfter) continue;
      contact.state = ContactState.archived;
      changed += 1;
    }
    return changed;
  }

  static Contact? byId(List<Contact> contacts, String id) {
    for (final Contact contact in contacts) {
      if (contact.id == id) return contact;
    }
    return null;
  }
}
