import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wisp/models/device.dart';
import 'package:wisp/models/transfer.dart';
import 'package:wisp/state/app_state.dart';

/// 拖拽进聊天窗口的文件：对端已经由会话确定，不该再弹「发给谁」。
void main() {
  // acceptDeviceForTest / openChat 会写联系人簿与会话，纯 test() 文件里
  // 必须先初始化 binding 并给 SharedPreferences 一个内存桩。
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('活跃会话 + 对端在线：直发，不进 draft、不动 composeTick', () async {
    final AppState state = AppState();
    final WispDevice device = WispDevice(
      alias: '客厅的 Mac mini',
      ip: '192.168.1.42',
      fingerprint: 'b' * 64,
      kind: DeviceKind.desktop,
    );
    state.acceptDeviceForTest(device);
    state.openChat(device); // activeChatKey 由 enterChat 设置

    final File file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}wisp_drop_test.txt')
      ..writeAsStringSync('hello');
    int sends = 0;
    WispDevice? sentTo;
    int sentFiles = 0;

    await state.addDroppedPaths(
      <String>[file.path],
      sendOverride: (WispDevice target, List<TransferFile> files) async {
        sends++;
        sentTo = target;
        sentFiles = files.length;
        return null;
      },
    );
    // banner 在异步发送完成后才写，给事件循环一拍。
    await Future<void>.delayed(Duration.zero);

    expect(sends, 1);
    expect(sentTo?.ip, device.ip);
    expect(sentFiles, 1);
    expect(state.draft, isEmpty, reason: '会话内直发不能污染待发清单');
    expect(state.composeTick, 0, reason: '不应打开发送页「发给谁」');
    expect(state.banner, contains('已把 1 个文件发给'));

    file.deleteSync();
  });

  test('没打开会话时仍走原来的待发清单 + 发送页流程', () async {
    final AppState state = AppState();
    final File file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}wisp_drop_test2.txt')
      ..writeAsStringSync('hello');
    int sends = 0;

    await state.addDroppedPaths(
      <String>[file.path],
      sendOverride: (WispDevice target, List<TransferFile> files) async {
        sends++;
        return null;
      },
    );

    expect(sends, 0);
    expect(state.draft.length, 1);
    expect(state.composeTick, 1);

    file.deleteSync();
  });
}
