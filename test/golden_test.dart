@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:wisp/core/design/app_theme.dart';
import 'package:wisp/models/contact.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/models/message.dart';
import 'package:wisp/models/transfer.dart';
import 'package:wisp/services/settings_service.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/contacts_page.dart';
import 'package:wisp/ui/pages/messages_page.dart';
import 'package:wisp/ui/pages/send_page.dart';
import 'package:wisp/ui/pages/settings_page.dart';
import 'package:wisp/ui/pages/transfer_page.dart';
import 'package:wisp/ui/shell/home_shell.dart';

import 'support/test_fonts.dart';

/// 生成真实渲染截图（golden）。
///
/// 跑法：flutter test test/golden_test.dart --update-goldens
/// 产物：test/goldens/*.png —— Flutter 真实渲染结果，不是设计稿。
///
/// 测试环境默认只有 Ahem 字体（中文和图标都会变成方块），
/// 所以这里显式加载系统中文字体和 Material 图标字体。
void main() {
  late String fontFamily;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    fontFamily = await loadTestFonts();
  });

  /// 固定的身份，让截图可复现。
  ///
  /// 生产环境的指纹来自 Random.secure()，每次安装都不同——那是对的，
  /// 但 golden 必须每次渲染出同一张图，所以这里注入一份写死的设置。
  final AppState state = AppState()
    ..settings = const WispSettings(
      alias: 'Tyler 的 MacBook',
      fingerprint: '42df24cbe1a07d3f9b6c8e5a2d4f1b73',
      deviceKind: DeviceKind.desktop,
    );

  Widget host(Widget child,
      {ThemeMode mode = ThemeMode.light, AppState? stateOverride}) {
    final ThemeData base = mode == ThemeMode.dark
        ? WispTheme.dark(fontFamily: fontFamily)
        : WispTheme.light(fontFamily: fontFamily);
    return ChangeNotifierProvider<AppState>.value(
      value: stateOverride ?? state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: base,
        home: Scaffold(body: child),
      ),
    );
  }

  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('golden: 联系人', (WidgetTester tester) async {
    usePhone(tester);
    state.acceptDeviceForTest(WispDevice(
      alias: 'Tyler 的 iPhone',
      ip: '192.168.1.31',
      fingerprint: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      kind: DeviceKind.mobile,
    ));
    state.acceptDeviceForTest(WispDevice(
      alias: '客厅的 Mac mini',
      ip: '192.168.1.42',
      fingerprint: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      kind: DeviceKind.desktop,
    ));
    // acceptDeviceForTest 会顺手把联系人写进簿里（临时态）；把一台标成保留，
    // 分组标题和置顶图钉就能一起入镜。
    final Contact first = state.contacts.first;
    first.state = ContactState.kept;

    await tester.pumpWidget(host(const ContactsPage()));
    await tester.pump(const Duration(milliseconds: 900));
    await expectLater(find.byType(ContactsPage), matchesGoldenFile('goldens/18-contacts.png'));

    // 共用同一个 state，用完清空，避免影响后续用例。
    state.contacts.clear();
    state.devices.clear();
  });

  testWidgets('golden: 发送', (WidgetTester tester) async {
    usePhone(tester);
    await tester.pumpWidget(host(const SendPage()));
    await tester.pump(const Duration(milliseconds: 900));
    await expectLater(find.byType(SendPage), matchesGoldenFile('goldens/02-send.png'));
  });

  testWidgets('golden: 传输', (WidgetTester tester) async {
    usePhone(tester);
    final TransferSession session = TransferSession(
      id: 'g1',
      peerAlias: 'Tyler 的 iPhone',
      peerIp: '192.168.1.31',
      direction: TransferDirection.outgoing,
      peerKind: DeviceKind.mobile,
      files: <TransferFile>[
        TransferFile(id: 'f1', name: '海边日落.jpg', size: 4404019)..sent = 4404019,
        TransferFile(id: 'f2', name: '产品方案 v3.pdf', size: 19293798)..sent = 10485760,
      ],
    )..status = TransferStatus.active;

    await tester.pumpWidget(host(TransferPage(session: session)));
    await tester.pump(const Duration(milliseconds: 900));
    await expectLater(find.byType(TransferPage), matchesGoldenFile('goldens/03-transfer.png'));
  });

  testWidgets('golden: 设置', (WidgetTester tester) async {
    usePhone(tester);
    await tester.pumpWidget(host(const SettingsPage()));

    await tester.pump(const Duration(milliseconds: 900));
    await expectLater(find.byType(SettingsPage), matchesGoldenFile('goldens/04-settings.png'));
  });

  testWidgets('golden: 主容器（深色）', (WidgetTester tester) async {
    usePhone(tester);
    await tester.pumpWidget(host(const HomeShell(), mode: ThemeMode.dark));
    await tester.pump(const Duration(milliseconds: 900));
    await expectLater(find.byType(HomeShell), matchesGoldenFile('goldens/05-shell-dark.png'));
  });

  // 桌面窗口最窄 420 逻辑像素（原生层 WM_GETMINMAXINFO 限制）。
  // 这两张就是"窄窗口不会错位"的看门狗。
  void useNarrowWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(840, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('golden: 窄窗口主容器', (WidgetTester tester) async {
    useNarrowWindow(tester);
    await tester.pumpWidget(host(const HomeShell()));
    await tester.pump(const Duration(milliseconds: 900));
    await expectLater(find.byType(HomeShell), matchesGoldenFile('goldens/08-narrow-shell.png'));
  });

  testWidgets('golden: 窄窗口设置', (WidgetTester tester) async {
    useNarrowWindow(tester);
    await tester.pumpWidget(host(const SettingsPage()));
    await tester.pump(const Duration(milliseconds: 900));
    await expectLater(find.byType(SettingsPage), matchesGoldenFile('goldens/09-narrow-settings.png'));
  });

  // 横屏：手机横过来（844 × 390 逻辑像素）——应切到侧边导航 + 多栏布局。
  void useLandscape(WidgetTester tester) {
    tester.view.physicalSize = const Size(2532, 1170);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('golden: 主容器（横屏侧栏）', (WidgetTester tester) async {
    useLandscape(tester);
    await tester.pumpWidget(host(const HomeShell()));
    await tester.pump(const Duration(milliseconds: 900));
    await expectLater(find.byType(HomeShell), matchesGoldenFile('goldens/10-shell-landscape.png'));
  });

  testWidgets('golden: 设置（横屏双列）', (WidgetTester tester) async {
    useLandscape(tester);
    await tester.pumpWidget(host(const SettingsPage()));
    await tester.pump(const Duration(milliseconds: 900));
    await expectLater(find.byType(SettingsPage), matchesGoldenFile('goldens/11-settings-landscape.png'));
  });

  testWidgets('golden: 发送（横屏双列）', (WidgetTester tester) async {
    useLandscape(tester);
    state.acceptDeviceForTest(WispDevice(
      alias: 'Tyler 的 iPhone',
      ip: '192.168.1.31',
      fingerprint: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      kind: DeviceKind.mobile,
    ));
    state.acceptDeviceForTest(WispDevice(
      alias: '客厅的 Mac mini',
      ip: '192.168.1.42',
      fingerprint: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      kind: DeviceKind.desktop,
    ));
    await tester.pumpWidget(host(const SendPage()));
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(SendPage), matchesGoldenFile('goldens/13-send-landscape.png'));
    state.devices.clear();
  });

  // 消息列表：会话行 + 未读角标 + 在线小绿点。
  //
  // 时间用 DateTime.now()：`Format.relative` 对 60 秒内的消息一律显示"刚刚"，
  // 这样每次渲染都稳定；换成固定日期的话，今天显示"3 天前"、一周后变成
  // "9 月 1 日"，基准图第二天就红了。
  testWidgets('golden: 消息列表', (WidgetTester tester) async {
    usePhone(tester);
    final DateTime now = DateTime.now();
    state.acceptDeviceForTest(WispDevice(
      alias: 'Tyler 的 iPhone',
      ip: '192.168.1.31',
      fingerprint: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      kind: DeviceKind.mobile,
    ));
    state.acceptDeviceForTest(WispDevice(
      alias: '客厅的 Mac mini',
      ip: '192.168.1.42',
      fingerprint: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      kind: DeviceKind.desktop,
    ));
    state.seedConversationForTest(Conversation(
      peerKey: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      peerAlias: 'Tyler 的 iPhone',
      peerIp: '192.168.1.31',
      unread: 2,
      messages: <ChatMessage>[
        ChatMessage(
          id: 'm1',
          direction: MessageDirection.outgoing,
          text: '把刚才那段命令发我一下',
          time: now.subtract(const Duration(seconds: 20)),
        ),
        ChatMessage(
          id: 'm2',
          direction: MessageDirection.incoming,
          text: 'flutter test --exclude-tags golden',
          time: now.subtract(const Duration(seconds: 5)),
        ),
      ],
    ));
    state.seedConversationForTest(Conversation(
      peerKey: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      peerAlias: '客厅的 Mac mini',
      peerIp: '192.168.1.42',
      messages: <ChatMessage>[
        ChatMessage(
          id: 'm3',
          direction: MessageDirection.incoming,
          text: '收到，我这边已经跑起来了',
          time: now.subtract(const Duration(seconds: 30)),
        ),
      ],
    ));

    await tester.pumpWidget(host(const MessagesPage()));
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(MessagesPage), matchesGoldenFile('goldens/16-messages.png'));

    // 共用一个 state，用完清空，避免污染后面的用例。
    state.conversations.clear();
    state.devices.clear();
  });

  // 三栏聊天主场：这是本轮改造的主界面，必须有一张真实渲染的基准图。
  // 之前的截图最宽只到 800×600（走单栏分支），三栏布局等于零覆盖。
  // 时间全部写死，否则气泡上的时钟会让基准图每分钟变一次。
  testWidgets('golden: 三栏聊天主场（1440x900）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final AppState three = AppState()
      ..settings = const WispSettings(
        alias: 'Tyler 的 MacBook',
        fingerprint: '42df24cbe1a07d3f9b6c8e5a2d4f1b73',
        deviceKind: DeviceKind.desktop,
      );
    three.acceptDeviceForTest(WispDevice(
      alias: 'Tyler 的 iPhone',
      ip: '192.168.1.31',
      fingerprint: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      kind: DeviceKind.mobile,
    ));
    three.acceptDeviceForTest(WispDevice(
      alias: '客厅的 Mac mini',
      ip: '192.168.1.42',
      fingerprint: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      kind: DeviceKind.desktop,
    ));
    final DateTime t = DateTime(2026, 1, 1, 10, 30);
    three.seedConversationForTest(Conversation(
      peerKey: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      peerAlias: 'Tyler 的 iPhone',
      peerIp: '192.168.1.31',
      messages: <ChatMessage>[
        ChatMessage(
          id: 'm1',
          direction: MessageDirection.outgoing,
          text: '把昨天拍的照片发我一下',
          time: t,
        ),
        ChatMessage(
          id: 'm2',
          direction: MessageDirection.incoming,
          text: '好，三张一起发，注意查收',
          time: t.add(const Duration(minutes: 1)),
        ),
        ChatMessage(
          id: 'files-3',
          direction: MessageDirection.incoming,
          text: '',
          time: t.add(const Duration(minutes: 2)),
          attachments: <ChatAttachment>[
            const ChatAttachment(
                name: '海边.jpg', size: 2483000, path: '', mime: 'image/jpeg'),
            const ChatAttachment(
                name: '报价.pdf', size: 184000, path: '', mime: 'application/pdf'),
            const ChatAttachment(
                name: '录音.m4a', size: 942000, path: '', mime: 'audio/mp4'),
          ],
        ),
      ],
    ));
    three.seedConversationForTest(Conversation(
      peerKey: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      peerAlias: '客厅的 Mac mini',
      peerIp: '192.168.1.42',
      messages: <ChatMessage>[
        ChatMessage(
          id: 'm3',
          direction: MessageDirection.incoming,
          text: '构建跑完了，全绿',
          time: t.subtract(const Duration(hours: 1)),
        ),
      ],
    ));

    await tester.pumpWidget(
        host(const MessagesPage(), stateOverride: three));
    await tester.pump(const Duration(milliseconds: 900));

    // 选中第一个会话，中栏消息流 + 右栏身份卡才会出现。
    await tester.tap(find.text('Tyler 的 iPhone').first);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));

    // 出现两次：左栏会话摘要 + 中栏折叠附件卡。
    expect(find.text('共 3 个文件'), findsNWidgets(2),
        reason: '三栏截图里应该能看到默认折叠的附件卡');
    await expectLater(find.byType(MessagesPage),
        matchesGoldenFile('goldens/17-three-column.png'));
  });

  // 最小窗口看门狗：窗口再怎么缩，首页所有元素（页头、身份卡、雷达、
  // 说明文案、「输入 IP 直接连接」按钮）都必须一屏放得下，不允许滚动。
  // 一旦有人加了留白把内容顶高，这里会立刻失败。
  testWidgets('golden: 最小窗口 420x690', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 690);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(const HomeShell()));
    await tester.pump(const Duration(milliseconds: 900));

    final ScrollableState vertical = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .firstWhere((ScrollableState s) => s.position.axis == Axis.vertical);
    expect(vertical.position.maxScrollExtent, 0,
        reason: '最小窗口下首页不该需要滚动，说明布局留白又变大了');

    await expectLater(
        find.byType(HomeShell), matchesGoldenFile('goldens/14-min-window.png'));
  });
}
