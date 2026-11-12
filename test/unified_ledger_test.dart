import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wisp/models/message.dart';
import 'package:wisp/models/transfer.dart';
import 'package:wisp/services/message_service.dart';
import 'package:wisp/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('ChatAttachment 与文件消息都能 JSON 往返', () {
    const ChatAttachment attachment = ChatAttachment(
      name: '海边 (1).jpg',
      size: 2100000,
      path: '/downloads/海边 (1).jpg',
      mime: 'image/jpeg',
    );
    final ChatAttachment restored = ChatAttachment.fromJson(attachment.toJson());
    expect(restored.name, attachment.name);
    expect(restored.path, attachment.path);
    expect(restored.mime, attachment.mime);
    expect(restored.isImage, isTrue);
    expect(restored.hasPath, isTrue);

    final ChatMessage message = ChatMessage(
      id: 'files-s1',
      direction: MessageDirection.incoming,
      text: '',
      time: DateTime(2026, 11, 12, 9, 41),
      attachments: <ChatAttachment>[attachment],
    );
    final ChatMessage back = ChatMessage.fromJson(message.toJson());
    expect(back.isFileMessage, isTrue);
    expect(back.attachments.single.path, attachment.path);
  });

  test('旧文字消息反序列化后仍是文字消息', () {
    final ChatMessage message = ChatMessage(
      id: 'm1',
      direction: MessageDirection.outgoing,
      text: '收到，我看看',
      time: DateTime(2026, 11, 12, 9, 43),
    );
    final ChatMessage back = ChatMessage.fromJson(message.toJson());
    expect(back.text, '收到，我看看');
    expect(back.hasAttachments, isFalse);
    expect(back.isFileMessage, isFalse);
  });

  test('会话摘要：文件消息不显示空白，多文件给「共 N 个文件」', () {
    final Conversation single = Conversation(
      peerKey: 'fp-A',
      peerAlias: 'Peer',
      peerIp: '192.168.1.24',
      messages: <ChatMessage>[
        ChatMessage(
          id: 'f1',
          direction: MessageDirection.incoming,
          text: '',
          time: DateTime(2026, 11, 12),
          attachments: <ChatAttachment>[
            const ChatAttachment(name: '合同.pdf', size: 100, path: ''),
          ],
        ),
      ],
    );
    expect(single.preview, '文件 · 合同.pdf');
    single.messages.add(ChatMessage(
      id: 'f2',
      direction: MessageDirection.incoming,
      text: '',
      time: DateTime(2026, 11, 12, 1),
      attachments: <ChatAttachment>[
        const ChatAttachment(name: '合同.pdf', size: 100, path: ''),
        const ChatAttachment(name: '报价.pdf', size: 100, path: ''),
      ],
    ));
    expect(single.preview, '共 2 个文件');
  });

  test('normalized 只排序，不再删任何会话或消息', () {
    final List<Conversation> list = List<Conversation>.generate(
      60,
      (int i) => Conversation(
        peerKey: 'fp-$i',
        peerAlias: 'Peer $i',
        peerIp: '192.168.1.$i',
        messages: <ChatMessage>[
          ChatMessage(
            id: 'm$i',
            direction: MessageDirection.incoming,
            text: 'msg $i',
            time: DateTime(2026, 11, 12).add(Duration(minutes: i)),
          ),
        ],
      ),
    );
    final List<Conversation> result = MessageService.normalized(list);
    expect(result.length, 60, reason: '超出 40 条只归档，不能 sublist 真删');
    expect(result.first.peerKey, 'fp-59', reason: '仍要按最近消息倒序');
  });

  test('一次文件传输写进统一账本，paths 与 fileNames 严格对齐', () {
    final TransferSession session = TransferSession(
      id: 's-1',
      peerAlias: '客厅的 Mac mini',
      peerIp: '192.168.1.24',
      direction: TransferDirection.incoming,
      files: <TransferFile>[
        TransferFile(id: 'f1', name: '海边.jpg', size: 100, mime: 'image/jpeg'),
        TransferFile(id: 'f2', name: '报价.pdf', size: 200, mime: 'application/pdf'),
      ],
      peerFingerprint: 'fp-A',
      status: TransferStatus.completed,
    )..savedPaths.addAll(<String, String>{
        'f1': '/downloads/海边 (1).jpg', // safeFileName 改名 + 重名后缀
        'f2': '/downloads/报价.pdf',
      });

    final AppState state = AppState();
    state.finishSessionForTest(session);

    expect(state.conversations.length, 1);
    expect(state.conversations.first.peerKey, 'fp-A',
        reason: '会话按 fingerprint 归属，不按 IP');
    final ChatMessage entry = state.conversations.first.messages.single;
    expect(entry.isFileMessage, isTrue);
    expect(entry.attachments.length, 2);
    expect(entry.attachments[0].name, '海边.jpg');
    expect(entry.attachments[0].path, '/downloads/海边 (1).jpg',
        reason: '缩略图必须用真实落盘路径，不能按目录 + 原始名拼');
    expect(entry.attachments[1].mime, 'application/pdf');
    expect(state.conversations.first.preview, '共 2 个文件');
    expect(state.history.length, 1, reason: 'history 仍双写，记录页与重发不受影响');
    expect(state.history.first.paths[0], '/downloads/海边 (1).jpg');
  });

  test('同一设备的文字与文件落在同一个会话', () {
    final AppState state = AppState();
    state.seedConversationForTest(Conversation(
      peerKey: 'fp-A',
      peerAlias: 'Peer',
      peerIp: '192.168.1.24',
      messages: <ChatMessage>[
        ChatMessage(
          id: 'm1',
          direction: MessageDirection.outgoing,
          text: '先发你看看',
          time: DateTime(2026, 11, 12, 9, 40),
        ),
      ],
    ));
    final TransferSession session = TransferSession(
      id: 's-2',
      peerAlias: 'Peer',
      peerIp: '10.0.0.7', // 换了网段
      direction: TransferDirection.outgoing,
      files: <TransferFile>[
        TransferFile(id: 'f1', name: '设计稿.png', size: 50, mime: 'image/png'),
      ],
      peerFingerprint: 'fp-A',
      status: TransferStatus.completed,
    );
    state.finishSessionForTest(session);

    expect(state.conversations.length, 1, reason: '换 Wi-Fi 不该分裂出第二个会话');
    expect(state.conversations.first.messages.length, 2);
    expect(state.conversations.first.messages.first.text, '先发你看看');
    expect(state.conversations.first.messages.last.hasAttachments, isTrue);
  });
}
