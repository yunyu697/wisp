import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/transfer.dart';

/// 传输历史，本地存 JSON 数组，全量保留（超出建议数量只归档、不删除）。
class HistoryService {
  static const String _key = 'wisp.history.v1';

  /// UI 主列表建议展示的历史条数，**不再用于删除**：超出只归档、全量落盘，
  /// P1 再做归档分区与搜索。
  static const int limit = 120;

  Future<List<TransferRecord>> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null) return <TransferRecord>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) return <TransferRecord>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(TransferRecord.fromJson)
          .toList()
        ..sort((TransferRecord a, TransferRecord b) => b.time.compareTo(a.time));
    } on FormatException {
      return <TransferRecord>[];
    }
  }

  Future<void> save(List<TransferRecord> records) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    // 全量落盘：超出 [limit] 的只是"归档"，不再 sublist 截断删除，
    // P1 再做归档分区与搜索。
    await prefs.setString(
      _key,
      jsonEncode(records.map((TransferRecord r) => r.toJson()).toList()),
    );
  }
}
