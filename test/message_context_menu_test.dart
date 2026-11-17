import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisp/core/design/app_theme.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/models/message.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/chat_page.dart';

/// 鼠标右键的 buttons 位掩码（dart:ui 的 kSecondaryButton）。
const int _secondaryButton = 0x02;

/// 聊天记录右键菜单护栏。
///
/// 用户反馈：「聊天记录点右键完全没有功能，连最基本的文本复制、文件打开
/// 所在文件夹都没有」。现在桌面右键文字/文件消息都应就地弹出菜单，且动作
/// 齐全（复制文字/文件名、打开文件、打开所在文件夹、删除）。
void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });

  Widget host(Widget child, AppState state) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: WispTheme.light(), home: Scaffold(body: child)),
      );

  AppState stateWithMessage(ChatMessage message) {
    final AppState state = AppState();
    final WispDevice device = WispDevice(
      alias: '客厅的 Mac mini',
      ip: '192.168.1.42',
      fingerprint: 'b' * 32,
      kind: DeviceKind.desktop,
    );
    state.acceptDeviceForTest(device);
    state.seedConversationForTest(Conversation(
      peerKey: device.key,
      peerAlias: device.alias,
      peerIp: device.ip,
      messages: <ChatMessage>[message],
    ));
    return state;
  }

  testWidgets('桌面右键文字消息：菜单有复制文字与删除',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final AppState state = stateWithMessage(ChatMessage(
      id: 'm1',
      direction: MessageDirection.incoming,
      text: '这条要复制的文字',
      time: DateTime.now(),
    ));
    await tester.pumpWidget(
        host(ChatPage(peerKey: state.conversations.first.peerKey, embedded: true), state));
    await tester.pumpAndSettle();

    // 右键点在正文气泡上。
    await tester.tap(find.text('这条要复制的文字'),
        buttons: _secondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('复制文字'), findsOneWidget);
    expect(find.text('删除这条消息'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('桌面右键文件消息：菜单有打开文件/所在文件夹/复制文件名',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 造一个真实存在的文件，右键菜单才会给出「打开文件 / 打开所在文件夹」。
    final File f = File('${Directory.systemTemp.path}${Platform.pathSeparator}wisp_ctx_menu_test.txt');
    f.writeAsStringSync('hello');
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });

    final AppState state = stateWithMessage(ChatMessage(
      id: 'm2',
      direction: MessageDirection.incoming,
      text: '',
      time: DateTime.now(),
      attachments: <ChatAttachment>[
        ChatAttachment(
          name: 'wisp_ctx_menu_test.txt',
          size: 5,
          path: f.path,
          mime: 'text/plain',
        ),
      ],
    ));
    await tester.pumpWidget(
        host(ChatPage(peerKey: state.conversations.first.peerKey, embedded: true), state));
    await tester.pumpAndSettle();

    // 右键点在附件卡片上。
    await tester.tap(find.text('wisp_ctx_menu_test.txt').first,
        buttons: _secondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('复制文件名'), findsOneWidget);
    expect(find.text('打开文件'), findsOneWidget);
    expect(find.text('打开所在文件夹'), findsOneWidget);
    expect(find.text('删除这条消息'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
