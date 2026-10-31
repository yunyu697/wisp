import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/models/transfer.dart';
import 'package:wisp/services/receiver_service.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/shell/home_shell.dart';

/// 伪造一个接收请求。
IncomingRequest _fakeRequest() {
  return IncomingRequest(
    sender: WispDevice(
      alias: 'Peer',
      ip: '127.0.0.1',
      fingerprint: 'fake',
      port: 53317,
      https: false,
    ),
    files: <TransferFile>[
      TransferFile(id: 'f1', name: 'probe.bin', size: 1024),
    ],
  );
}

Future<void> _pumpSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('连续两次收到请求，弹层都要弹出来', (WidgetTester tester) async {
    final AppState state = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: HomeShell()),
      ),
    );
    await tester.pump();

    // 第一次请求：应用内弹层必须出来。
    state.handleIncomingRequest(_fakeRequest());
    await _pumpSheet(tester);
    expect(find.text('接收'), findsOneWidget, reason: '第一次请求：弹层没有出现');

    // 用户拒绝，弹层收起。
    state.rejectIncoming();
    await _pumpSheet(tester);
    expect(find.text('接收'), findsNothing, reason: '拒绝后弹层没有收起');

    // 第二次请求：弹层必须重新弹出来。
    // 这一条正是用户反馈的"要第二次才会出现"——处理完一次之后再来请求，
    // 弹层（以及桌面通知）就再也不出现了。
    state.handleIncomingRequest(_fakeRequest());
    await _pumpSheet(tester);
    expect(find.text('接收'), findsOneWidget, reason: '第二次请求：弹层没有再出现');
  });

  testWidgets('弹层收起后首页必须还在', (WidgetTester tester) async {
    final AppState state = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: HomeShell()),
      ),
    );
    await tester.pump();

    state.handleIncomingRequest(_fakeRequest());
    await _pumpSheet(tester);
    expect(find.text('接收'), findsOneWidget);

    state.rejectIncoming();
    await _pumpSheet(tester);
    expect(state.incoming, isNull);
    // 首页路由被误弹出的话，整个应用会变成一片空白——
    // 用户看到的"主窗口变黑"很可能就是它。
    expect(find.byType(HomeShell), findsOneWidget,
        reason: '首页路由被误弹出，应用变成空白页');
  });
}
