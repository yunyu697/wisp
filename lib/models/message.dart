import 'device.dart';

/// 一条文本消息的方向。
enum MessageDirection { incoming, outgoing }
/// 出站消息的投递状态。入站消息恒为 [MessageStatus.sent]。
enum MessageStatus { sending, sent, failed }

/// 聊天里的一条文本消息。
///
/// 和 `TransferFile` 是两条完全独立的链路：消息只存在于内存与
/// SharedPreferences 里，**不落文件**。用户要的是"像 IM 那样发一段话"，
/// 不是"把这段话存成 .txt 再传过去"。
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.direction,
    required this.text,
    required this.time,
    this.status = MessageStatus.sent,
    this.error,
  });

  final String id;
  final MessageDirection direction;
  final String text;
  final DateTime time;

  MessageStatus status;
  String? error;

  bool get isOutgoing => direction == MessageDirection.outgoing;
  bool get failed => status == MessageStatus.failed;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'dir': direction.name,
        'text': text,
        'time': time.toIso8601String(),
        // 只有失败态值得写盘：重启之后还显示一个红叹号是有意义的，
        // 而"发送中"重启后必然已经不在飞了，按已发送处理更不吓人。
        if (status == MessageStatus.failed) 'status': status.name,
        if (error != null) 'error': error,
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
  String get preview {
    final ChatMessage? message = last;
    if (message == null) return '还没有消息';
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

  /// 只保留最近 [limit] 条。
  ///
  /// 会话是长期存在的，不截断的话一个挂着跑几个月的客户端会把整段聊天
  /// 历史一直堆在内存和 SharedPreferences 里。
  void trim(int limit) {
    if (messages.length <= limit) return;
    messages.removeRange(0, messages.length - limit);
  }

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
