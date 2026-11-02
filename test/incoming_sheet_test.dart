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

/// 只为了在测试里手动触发一次状态通知。
///
/// `notifyListeners` 是 `@protected`，子类里调用是正当用法；用它来模拟
/// "同一帧里连着来好几趟 notifyListeners" 这种真实情况。
class _PingableState extends AppState {
  void ping() => notifyListeners();
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

  // 用户报的"通过桌面通知/悬浮球接收文件后，再打开主窗口 100% 黑屏"。
  //
  // 根因不在原生层：一次接收流程里 `notifyListeners` 会连着来好几趟
  // （清 incoming、开传输、第一帧进度…）。旧代码每来一趟都调度一次
  // `Navigator.pop()`——第一趟关掉弹层，第二趟把 home 路由也弹掉。
  // Navigator 空了之后框架什么都不画，窗口客户区整块纯黑，而且再也回不来
  // （实测：框架自己抓图 368 字节全透明、帧心跳停摆、resize/重绘/隐藏再显示
  //  全都不管用）。
  testWidgets('弹层收起的同一帧里再来通知，首页路由也不能被弹掉',
      (WidgetTester tester) async {
    final _PingableState state = _PingableState();
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

    // 请求在别处（气泡/通知卡）被处理掉，同一帧里还跟着两趟别的通知。
    state.rejectIncoming();
    state.ping();
    state.ping();
    await _pumpSheet(tester);
    await tester.pump(const Duration(milliseconds: 600));

    expect(state.incoming, isNull);
    expect(find.byType(HomeShell), findsOneWidget,
        reason: '首页路由被误弹出：Navigator 变空，整个窗口会变成纯黑');
    // 弹层本身要收干净，不能为了保住 home 就把弹层留在那儿。
    expect(find.text('接收'), findsNothing);
  });
}
