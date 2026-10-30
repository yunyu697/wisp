import 'package:flutter/material.dart';

/// 展示层的格式化工具：字节、速率、时间、相对时间。
class Format {
  const Format._();

  static String bytes(num value) {
    if (value < 1024) return '${value.toInt()} B';
    const List<String> units = <String>['KB', 'MB', 'GB', 'TB'];
    double v = value / 1024;
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
  }

  static String speed(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return '—';
    return '${bytes(bytesPerSecond)}/s';
  }

  static String duration(Duration d) {
    if (d.inSeconds < 1) return '不到 1 秒';
    if (d.inSeconds < 60) return '${d.inSeconds} 秒';
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    if (m < 60) return s == 0 ? '$m 分钟' : '$m 分 $s 秒';
    return '${d.inHours} 小时 ${m % 60} 分';
  }

  /// 「刚刚 / 12 分钟前 / 昨天 18:20」这类相对时间，比时间戳更好读。
  static String relative(DateTime time) {
    final DateTime now = DateTime.now();
    final Duration diff = now.difference(time);
    if (diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24 && now.day == time.day) return '今天 ${clock(time)}';
    final DateTime yesterday = now.subtract(const Duration(days: 1));
    if (yesterday.day == time.day && yesterday.month == time.month) {
      return '昨天 ${clock(time)}';
    }
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${time.month} 月 ${time.day} 日';
  }

  static String clock(DateTime time) {
    final String h = time.hour.toString().padLeft(2, '0');
    final String m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  static String dayLabel(DateTime time) {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime target = DateTime(time.year, time.month, time.day);
    final int delta = today.difference(target).inDays;
    if (delta == 0) return '今天';
    if (delta == 1) return '昨天';
    if (delta < 7) return '$delta 天前';
    return '${time.year} 年 ${time.month} 月 ${time.day} 日';
  }
}

/// 图标/配色与文件类型绑定，让列表一眼能扫。
class FileKind {
  const FileKind._();

  static IconData iconFor(String fileName) {
    final String ext = _ext(fileName);
    if (_in(ext, <String>['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp', 'svg'])) {
      return Icons.image_rounded;
    }
    if (_in(ext, <String>['mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v'])) {
      return Icons.movie_rounded;
    }
    if (_in(ext, <String>['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg'])) {
      return Icons.graphic_eq_rounded;
    }
    if (_in(ext, <String>['pdf'])) return Icons.picture_as_pdf_rounded;
    if (_in(ext, <String>['zip', 'rar', '7z', 'tar', 'gz'])) return Icons.folder_zip_rounded;
    if (_in(ext, <String>['doc', 'docx', 'pages', 'txt', 'md'])) return Icons.description_rounded;
    if (_in(ext, <String>['xls', 'xlsx', 'csv', 'numbers'])) return Icons.table_chart_rounded;
    if (_in(ext, <String>['ppt', 'pptx', 'key'])) return Icons.slideshow_rounded;
    if (_in(ext, <String>['apk', 'exe', 'dmg', 'msi', 'appimage'])) return Icons.memory_rounded;
    return Icons.insert_drive_file_rounded;
  }

  static Color colorFor(String fileName) {
    final String ext = _ext(fileName);
    if (_in(ext, <String>['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp', 'svg'])) {
      return const Color(0xFF34C759);
    }
    if (_in(ext, <String>['mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v'])) {
      return const Color(0xFFFF6B8A);
    }
    if (_in(ext, <String>['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg'])) {
      return const Color(0xFFFF9F0A);
    }
    if (_in(ext, <String>['pdf'])) return const Color(0xFFFF3B30);
    if (_in(ext, <String>['zip', 'rar', '7z', 'tar', 'gz'])) return const Color(0xFF8E8E93);
    if (_in(ext, <String>['xls', 'xlsx', 'csv', 'numbers'])) return const Color(0xFF30B15A);
    if (_in(ext, <String>['ppt', 'pptx', 'key'])) return const Color(0xFFFF7A2F);
    return const Color(0xFF5B7BFF);
  }

  static String _ext(String name) {
    final int dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  static bool _in(String value, List<String> set) => set.contains(value);
}
