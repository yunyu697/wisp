import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wisp/models/message.dart';
import 'package:wisp/ui/widgets/attachment_bundle.dart';

/// 聊天记录里的非图片附件：以前 onTap 是 null，点了完全没反应。
void main() {
  testWidgets('点普通文件至少给出一句反馈', (WidgetTester tester) async {
    const ChatAttachment attachment = ChatAttachment(
      name: 'report.pdf',
      size: 1024,
      path: '/no/such/path/report.pdf',
      mime: 'application/pdf',
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AttachmentBundle(
            attachments: const <ChatAttachment>[attachment],
            expanded: false,
            onToggle: () {},
            outgoing: false,
          ),
        ),
      ),
    ));

    await tester.tap(find.text('report.pdf').first);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('文件已不在原来的位置'), findsOneWidget);
  });
}
