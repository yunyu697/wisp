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

  /// UI 主列表建议展示的会话数，**不再用于删除**：超出的只归档、全量保留，
  /// P1 再做归档分区与搜索。
  static const int conversationLimit = 40;

  /// 单个会话建议展示的消息数，同样**不再用于删除**（见 normalized）。
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

  /// 落盘前的统一收口：只按最近消息排序，**不再删任何记录**。
  ///
  /// 超出 [conversationLimit] / [messageLimit] 的只是"归档"，记录全量保留，
  /// 主列表按建议数量展示即可；P1 再做归档分区与搜索，绝不在这里截断删除。
  /// 抽成纯函数是为了能直接对排序行为写断言，不必真的读写 SharedPreferences。
  static List<Conversation> normalized(List<Conversation> conversations) {
    return List<Conversation>.of(conversations)
      ..sort((Conversation a, Conversation b) => b.lastTime.compareTo(a.lastTime));
  }
}
