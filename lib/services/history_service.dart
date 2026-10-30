import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/transfer.dart';

/// 传输历史，本地存 JSON 数组，最多保留 120 条。
class HistoryService {
  static const String _key = 'wisp.history.v1';

  /// 历史条数上限。内存里的列表也按这个截断，否则长期运行会一直涨。
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
    final List<TransferRecord> trimmed =
        records.length > limit ? records.sublist(0, limit) : records;
    await prefs.setString(
      _key,
      jsonEncode(trimmed.map((TransferRecord r) => r.toJson()).toList()),
    );
  }
}
