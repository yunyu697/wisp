import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';

/// 聊天记录的本地存储。
///
/// 和 `HistoryService` 一样用 SharedPreferences 存一段 JSON，但两者刻意分开：
/// 传输历史是"传过什么文件"的流水账，聊天记录是"和谁说过什么"的长期对话，
/// 生命周期、条数上限、清理时机都不一样，混在一个 key 里迟早互相拖累。
class MessageService {
  static const String _key = 'wisp.chats.v1';

  /// 最多保留多少个会话（按最近一条消息排序）。
  static const int conversationLimit = 40;

  /// 单个会话最多保留多少条消息。
  static const int messageLimit = 300;

  Future<List<Conversation>> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null) return <Conversation>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) return <Conversation>[];
      final List<Conversation> list = decoded
          .whereType<Map<String, dynamic>>()
          .map(Conversation.fromJson)
          .where((Conversation c) => c.peerKey.isNotEmpty)
          .toList();
      return normalized(list);
    } on FormatException {
      return <Conversation>[];
    }
  }

  Future<void> save(List<Conversation> conversations) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<Conversation> trimmed = normalized(conversations);
    await prefs.setString(
      _key,
      jsonEncode(trimmed.map((Conversation c) => c.toJson()).toList()),
    );
  }

  /// 落盘前的统一收口：按最近消息排序、截断会话数与单会话消息数。
  ///
  /// 抽成纯函数是为了能直接对"上限"写断言，不必真的读写 SharedPreferences。
  /// 注意它**修改传入的会话对象**（trim 是原地删除），返回的也是同一批引用——
  /// 内存里的列表和磁盘上的一致，界面上不会出现"刚发的消息下次启动就没了"。
  static List<Conversation> normalized(List<Conversation> conversations) {
    final List<Conversation> sorted = List<Conversation>.of(conversations)
      ..sort((Conversation a, Conversation b) => b.lastTime.compareTo(a.lastTime));
    final List<Conversation> kept = sorted.length > conversationLimit
        ? sorted.sublist(0, conversationLimit)
        : sorted;
    for (final Conversation conversation in kept) {
      conversation.trim(messageLimit);
    }
    return kept;
  }
}
