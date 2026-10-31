import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/models/transfer.dart';
import 'package:wisp/services/receiver_service.dart';
import 'package:wisp/state/app_state.dart';

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

/// 模拟原生层：记录收到的调用，并按脚本回答 surfaceStatus。
class _NativeStub {
  _NativeStub();

  final List<String> calls = <String>[];
  int showToastCount = 0;
  int showBubbleCount = 0;

  /// surfaceStatus 返回 drawn=true 之前要等的 show 次数。
  int drawnAfterShowCount = 1;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'windowState':
        return <String, Object?>{
          'visible': false,
          'active': false,
          'ballEnabled': false,
          'ballExpanded': false,
          'ballSnapped': false,
        };
      case 'showToast':
        showToastCount++;
        return null;
      case 'showBubble':
        showBubbleCount++;
        return null;
      case 'surfaceStatus':
        final bool drawn =
            showToastCount >= drawnAfterShowCount ||
                showBubbleCount >= drawnAfterShowCount;
        return <String, Object?>{
          'toast': <String, Object?>{
            'visible': drawn,
            'active': drawn,
            'drawn': drawn,
            'left': 100,
            'top': 100,
            'right': 400,
            'bottom': 300,
          },
          'bubble': <String, Object?>{
            'visible': drawn,
            'active': drawn,
            'drawn': drawn,
            'left': 100,
            'top': 100,
            'right': 400,
            'bottom': 300,
          },
        };
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('wisp/desktop');

  late _NativeStub stub;

  setUp(() {
    stub = _NativeStub();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, stub.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('第一次没画出来时必须重发通知卡', () async {
    // 第一次 showToast 之后原生层仍说"没画出来"。
    stub.drawnAfterShowCount = 2;
    final AppState state = AppState();
    state.handleIncomingRequest(_fakeRequest());
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(stub.showToastCount, greaterThanOrEqualTo(2),
        reason: '第一次没画出来时必须再发一次，而不是就此沉默');
  });

  test('一次就画出来时不该重复发送', () async {
    stub.drawnAfterShowCount = 1;
    final AppState state = AppState();
    state.handleIncomingRequest(_fakeRequest());
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(stub.showToastCount, 1);
  });

  test('拿不到窗口状态时也要弹通知，不能静默吞掉', () async {
    // windowState 直接失败（通道还没准备好）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      stub.calls.add(call.method);
      if (call.method == 'windowState') {
        throw PlatformException(code: 'boom');
      }
      return stub.handle(call);
    });
    final AppState state = AppState();
    state.handleIncomingRequest(_fakeRequest());
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(stub.showToastCount, greaterThanOrEqualTo(1),
        reason: '状态拿不到时也要弹通知：宁可多弹一次，也不能一声不吭');
  });
}
