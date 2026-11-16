import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// golden 截图前预热 t1 图标资源。
///
/// `Image.asset` 的解码是异步 I/O，`pump(Duration(milliseconds: 900))` 并不
/// 保证已完成。不预热时首次用到的资源会被截成空白——深色底栏和发送按钮
/// 就因此得到过"图标消失"的假象。ImageCache 在同一测试文件的用例之间共享，
/// 所以每个文件预热一次即可。
const List<String> kT1AssetPaths = <String>[
  'assets/icons/t1/ui/t1-chat-light-48.png',
  'assets/icons/t1/ui/t1-chat-dark-48.png',
  'assets/icons/t1/ui/t1-devices-light-48.png',
  'assets/icons/t1/ui/t1-devices-dark-48.png',
  'assets/icons/t1/ui/t1-transfers-light-48.png',
  'assets/icons/t1/ui/t1-transfers-dark-48.png',
  'assets/icons/t1/ui/t1-settings-light-48.png',
  'assets/icons/t1/ui/t1-settings-dark-48.png',
  'assets/icons/t1/ui/t1-receive-light-48.png',
  'assets/icons/t1/ui/t1-receive-dark-48.png',
  'assets/icons/t1/ui/t1-send-light-48.png',
  'assets/icons/t1/ui/t1-send-dark-48.png',
  'assets/icons/t1/app/t1-app-light-128.png',
  'assets/icons/t1/app/t1-app-dark-128.png',
];

Future<void> warmUpT1Icons(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  final BuildContext context = tester.element(find.byType(SizedBox));
  await tester.runAsync(() async {
    for (final String path in kT1AssetPaths) {
      await precacheImage(AssetImage(path), context);
    }
  });
  await tester.pump();
}
