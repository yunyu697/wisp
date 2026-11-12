import 'dart:io';

import 'device.dart';

enum TransferDirection { incoming, outgoing }

enum TransferStatus { pending, waiting, active, completed, failed, canceled, rejected }

extension TransferStatusX on TransferStatus {
  bool get isRunning => this == TransferStatus.active || this == TransferStatus.pending;
  bool get isFinished =>
      this == TransferStatus.completed ||
      this == TransferStatus.failed ||
      this == TransferStatus.canceled ||
      this == TransferStatus.rejected;

  String get label {
    switch (this) {
      case TransferStatus.pending:
        return '准备中';
      case TransferStatus.waiting:
        return '等待对方确认';
      case TransferStatus.active:
        return '传输中';
      case TransferStatus.completed:
        return '已完成';
      case TransferStatus.failed:
        return '失败';
      case TransferStatus.canceled:
        return '已取消';
      case TransferStatus.rejected:
        return '对方拒绝';
    }
  }
}

/// 传输队列里的一个文件。
class TransferFile {
  TransferFile({
    required this.id,
    required this.name,
    required this.size,
    this.path,
    this.mime = 'application/octet-stream',
    this.sha256,
    this.preview,
  });

  final String id;
  final String name;
  final int size;
  final String? path;
  final String mime;
  final String? sha256;

  /// 官方 LocalSend 文字/剪贴板消息的正文：prepare-upload 里 `text/plain`
  /// 文件内联的预览文本。普通文件为 null。
  final String? preview;

  /// 已传字节，用于单文件进度条。
  int sent = 0;

  double get progress => size <= 0 ? 1 : (sent / size).clamp(0.0, 1.0).toDouble();

  File? get file => path == null ? null : File(path!);

  Map<String, dynamic> toProtocolJson() => <String, dynamic>{
        'id': id,
        'fileName': name,
        'size': size,
        'fileType': mime,
        if (sha256 != null) 'sha256': sha256,
        if (preview != null) 'preview': preview,
      };

  factory TransferFile.fromProtocolJson(String id, Map<String, dynamic> json) => TransferFile(
        id: id,
        name: (json['fileName'] as String?) ?? '未命名文件',
        size: (json['size'] as num?)?.toInt() ?? 0,
        mime: (json['fileType'] as String?) ?? 'application/octet-stream',
        sha256: json['sha256'] as String?,
        preview: json['preview'] as String?,
      );
}

/// 一次传输会话（发送或接收）。
class TransferSession {
  TransferSession({
    required this.id,
    required this.peerAlias,
    required this.peerIp,
    required this.direction,
    required this.files,
    this.peerKind = DeviceKind.desktop,
    this.status = TransferStatus.pending,
    this.peerFingerprint,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  final String id;
  final String peerAlias;
  final String peerIp;
  final TransferDirection direction;
  final List<TransferFile> files;
  final DeviceKind peerKind;
  final DateTime startedAt;

  /// 对端证书 fingerprint：聊天式界面用它把这次传输挂回正确的会话，
  /// 换 Wi-Fi 后 IP 变了也不分裂。老设备可能为空，由状态层兜底。
  final String? peerFingerprint;

  TransferStatus status;
  String? error;

  /// 接收端把文件落到哪个目录（发送端恒为 null）。
  /// 结束写历史时带进记录，"打开所在目录"才有据可依。
  String? saveDir;

  /// 对端在 prepare 应答里签发的会话号。上传和取消都必须用它：
  /// 对端按自己的编号记账，拿本地 id 去对会被当成无效会话拒掉（403）。
  /// 之前一直用本地 id，自测里假服务器不校验所以没暴露。
  String? remoteSessionId;

  /// 令牌：接收端为每个文件签发，发送端按文件回传。
  final Map<String, String> tokens = <String, String>{};

  /// 入站文件按 fileId 记录**真实落盘路径**（safeFileName 改名 / 重名加后缀
  /// 之后的路径）。出站恒为空。写历史记录时用它把 paths 与 fileNames 对齐，
  /// 这样"打开所在目录 / 再次发送"才指得到真正的文件。
  final Map<String, String> savedPaths = <String, String>{};

  DateTime _sampleAt = DateTime.now();
  int _sampleBytes = 0;
  double bytesPerSecond = 0;

  int get totalBytes => files.fold(0, (int sum, TransferFile f) => sum + f.size);

  int get doneBytes => files.fold(0, (int sum, TransferFile f) => sum + f.sent);

  double get progress => totalBytes <= 0 ? 0 : (doneBytes / totalBytes).clamp(0.0, 1.0).toDouble();

  Duration? get remaining {
    if (bytesPerSecond <= 0) return null;
    final int left = totalBytes - doneBytes;
    if (left <= 0) return Duration.zero;
    return Duration(seconds: (left / bytesPerSecond).round());
  }

  /// 用滑动采样估算速率，避免瞬时抖动导致数字乱跳。
  void sample() {
    final DateTime now = DateTime.now();
    final int elapsedMs = now.difference(_sampleAt).inMilliseconds;
    if (elapsedMs < 400) return;
    final int delta = doneBytes - _sampleBytes;
    final double instant = delta * 1000 / elapsedMs;
    bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.6 + instant * 0.4;
    _sampleAt = now;
    _sampleBytes = doneBytes;
  }

  void cancel() {
    if (!status.isFinished) status = TransferStatus.canceled;
  }
}

/// 历史记录（可持久化）。
class TransferRecord {
  TransferRecord({
    required this.id,
    required this.peerAlias,
    required this.direction,
    required this.fileNames,
    required this.bytes,
    required this.time,
    required this.success,
    this.paths = const <String>[],
    this.saveDir,
    this.peerIp,
  });

  final String id;
  final String peerAlias;
  final TransferDirection direction;
  final List<String> fileNames;
  final int bytes;
  final DateTime time;
  final bool success;

  /// 出站记录的源文件路径，与 [fileNames] 一一对应。
  /// 旧版本记录里没有这个字段，所以允许为空——没有它就没法"再次发送"。
  final List<String> paths;

  /// 入站记录的落盘目录，用来"打开所在目录"。
  final String? saveDir;

  /// 对端 IP，用来在对方仍在线时把他顺手选中。
  final String? peerIp;

  /// 还能找到的源文件路径（用户可能已经移动或删除）。
  List<String> get existingPaths =>
      paths.where((String p) => File(p).existsSync()).toList();

  bool get canResend =>
      direction == TransferDirection.outgoing && existingPaths.isNotEmpty;

  int get count => fileNames.length;

  String get summary {
    if (fileNames.isEmpty) return '空传输';
    if (fileNames.length == 1) return fileNames.first;
    return '${fileNames.first} 等 ${fileNames.length} 个文件';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'peer': peerAlias,
        'direction': direction.name,
        'files': fileNames,
        'bytes': bytes,
        'time': time.toIso8601String(),
        'success': success,
        // 空值不写盘：老版本读到的仍是同一份结构，新版本按需补。
        if (paths.isNotEmpty) 'paths': paths,
        if (saveDir != null) 'saveDir': saveDir,
        if (peerIp != null) 'peerIp': peerIp,
      };

  factory TransferRecord.fromJson(Map<String, dynamic> json) => TransferRecord(
        id: (json['id'] as String?) ?? '',
        peerAlias: (json['peer'] as String?) ?? '未知设备',
        direction: json['direction'] == 'incoming'
            ? TransferDirection.incoming
            : TransferDirection.outgoing,
        fileNames: (json['files'] as List<dynamic>? ?? <dynamic>[])
            .map((dynamic e) => e.toString())
            .toList(),
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        time: DateTime.tryParse((json['time'] as String?) ?? '') ?? DateTime.now(),
        success: (json['success'] as bool?) ?? true,
        paths: (json['paths'] as List<dynamic>? ?? <dynamic>[])
            .map((dynamic e) => e.toString())
            .toList(),
        saveDir: json['saveDir'] as String?,
        peerIp: json['peerIp'] as String?,
      );
}
