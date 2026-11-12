import 'device.dart';

/// 一条文本消息的方向。
enum MessageDirection { incoming, outgoing }
/// 出站消息的投递状态。入站消息恒为 [MessageStatus.sent]。
enum MessageStatus { sending, sent, failed }

/// 统一账本里的一条附件：一次文件传输结束后写进会话，和文字消息同列表。
///
/// [path] 是**真实落盘路径**（入站已按 safeFileName 改名 / 加重名后缀后回填），
/// 缩略图与「打开所在目录」都靠它；为空表示源文件已不在，只显示文件名。
class ChatAttachment {
  const ChatAttachment({
    required this.name,
    required this.size,
    required this.path,
    this.mime = '',
  });

  final String name;
  final int size;
  final String path;
  final String mime;

  bool get isImage => mime.startsWith('image/');
  bool get hasPath => path.trim().isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'size': size,
        'path': path,
        'mime': mime,
      };

  factory ChatAttachment.fromJson(Map<String, dynamic> json) => ChatAttachment(
        name: (json['name'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        path: (json['path'] as String?) ?? '',
        mime: (json['mime'] as String?) ?? '',
      );
}

/// 聊天里的一条消息。
///
/// 文字走官方 `preview` 通道、图片和文件走标准 files 通道，但**在本地是同一份
/// 账本**：文字消息 [text] 有值、[attachments] 为空；文件消息反过来。这样
/// 「刚传的文件聊天里没有 / 记录页还有一份」不会再发生。
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.direction,
    required this.text,
    required this.time,
    this.status = MessageStatus.sent,
    this.error,
    List<ChatAttachment>? attachments,
  }) : attachments = attachments ?? <ChatAttachment>[];

  final String id;
  final MessageDirection direction;
  final String text;
  final DateTime time;
  final List<ChatAttachment> attachments;

  MessageStatus status;
  String? error;

  bool get isOutgoing => direction == MessageDirection.outgoing;
  bool get failed => status == MessageStatus.failed;
  bool get hasAttachments => attachments.isNotEmpty;
  bool get isFileMessage => hasAttachments && text.trim().isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'dir': direction.name,
        'text': text,
        'time': time.toIso8601String(),
        // 只有失败态值得写盘：重启之后还显示一个红叹号是有意义的，
        // 而"发送中"重启后必然已经不在飞了，按已发送处理更不吓人。
        if (status == MessageStatus.failed) 'status': status.name,
        if (error != null) 'error': error,
        if (attachments.isNotEmpty)
          'attachments':
              attachments.map((ChatAttachment a) => a.toJson()).toList(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: (json['id'] as String?) ?? '',
        direction: json['dir'] == 'outgoing'
            ? MessageDirection.outgoing
            : MessageDirection.incoming,
        text: (json['text'] as String?) ?? '',
        time: DateTime.tryParse((json['time'] as String?) ?? '') ?? DateTime.now(),
        status: json['status'] == 'failed' ? MessageStatus.failed : MessageStatus.sent,
        error: json['error'] as String?,
        attachments: (json['attachments'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(ChatAttachment.fromJson)
            .toList(),
      );
}

/// 与某台设备的会话。
///
/// [peerKey] 用 [WispDevice.key]（指纹优先、退化为 IP）而不是 IP：
/// 换 Wi-Fi 之后对端地址会变，按 IP 存会话就等于每次换网都丢历史。
class Conversation {
  Conversation({
    required this.peerKey,
    required this.peerAlias,
    required this.peerIp,
    List<ChatMessage>? messages,
    this.unread = 0,
  }) : messages = messages ?? <ChatMessage>[];

  final String peerKey;
  String peerAlias;
  String peerIp;
  final List<ChatMessage> messages;
  int unread;

  ChatMessage? get last => messages.isEmpty ? null : messages.last;

  DateTime get lastTime => last?.time ?? DateTime.fromMillisecondsSinceEpoch(0);

  /// 会话列表里那一行摘要：换行压成空格，超长截断。
  /// 文件消息没有正文，用「共 N 个文件」当摘要，别显示一个空字符串。
  String get preview {
    final ChatMessage? message = last;
    if (message == null) return '还没有消息';
    if (message.isFileMessage) {
      final int count = message.attachments.length;
      return count == 1
          ? '文件 · ${message.attachments.first.name}'
          : '共 $count 个文件';
    }
    final String flat = message.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= 60) return flat;
    return '${flat.substring(0, 60)}…';
  }

  void add(ChatMessage message) {
    messages.add(message);
    // 时间戳可能乱序（对端时钟不准、或离线消息晚到），插入后按时间稳定排序，
    // 保证气泡顺序永远是从旧到新。
    messages.sort((ChatMessage a, ChatMessage b) => a.time.compareTo(b.time));
  }

  /// 兼容保留的空实现：曾按 [limit] 删除旧消息，现在**不再删记录**——
  /// 超出上限的只是"归档"，聊天历史全量保留，P1 再做归档分区与搜索。
  /// 方法签名保留以免破坏调用方（[MessageService] 旧路径与相关测试）。
  void trim(int limit) {}

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': peerKey,
        'alias': peerAlias,
        'ip': peerIp,
        if (unread > 0) 'unread': unread,
        'messages': messages.map((ChatMessage m) => m.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        peerKey: (json['key'] as String?) ?? '',
        peerAlias: (json['alias'] as String?) ?? '未知设备',
        peerIp: (json['ip'] as String?) ?? '',
        unread: (json['unread'] as num?)?.toInt() ?? 0,
        messages: (json['messages'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList()
          ..sort((ChatMessage a, ChatMessage b) => a.time.compareTo(b.time)),
      );
}

/// 从网络上收到的一条消息（接收端解析完报文后交给状态层）。
///
/// 带上完整的 [sender] 而不是只留 IP：收到消息说明对方此刻可达，
/// 状态层可以顺手把它并进设备列表，用户立刻就能回一句。
class IncomingMessage {
  const IncomingMessage({
    required this.id,
    required this.text,
    required this.time,
    required this.sender,
  });

  final String id;
  final String text;
  final DateTime time;
  final WispDevice sender;
}
