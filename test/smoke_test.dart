import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:wisp/core/design/app_theme.dart';
import 'package:wisp/core/utils/format.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/models/transfer.dart';
import 'package:wisp/state/app_state.dart';
import 'package:wisp/ui/pages/contacts_page.dart';
import 'package:wisp/ui/pages/send_page.dart';
import 'package:wisp/ui/pages/transfer_page.dart';
import 'package:wisp/ui/widgets/device_tile.dart';

/// 冒烟测试：不碰网络，只验证"能不能正常渲染"和"协议字段解析对不对"。
///
/// 视口固定成 iPhone 尺寸，布局溢出会直接让测试失败——
/// 这比肉眼看截图可靠。
void main() {
  setUp(() {
    // 统一手机视口：390 × 844 @3x
    final TestWidgetsFlutterBinding binding = TestWidgetsFlutterBinding.ensureInitialized();
    final TestFlutterView view = binding.platformDispatcher.implicitView!;
    view.physicalSize = const Size(1170, 2532);
    view.devicePixelRatio = 3.0;
  });

  tearDown(() {
    final TestWidgetsFlutterBinding binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.implicitView!.reset();
  });

  Widget host(Widget child) {
    final AppState state = AppState();
    return ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: WispTheme.light(),
        darkTheme: WispTheme.dark(),
        home: Scaffold(body: child),
      ),
    );
  }

  group('格式化', () {
    test('字节按量级换单位', () {
      expect(Format.bytes(512), '512 B');
      expect(Format.bytes(2048), '2.0 KB');
      expect(Format.bytes(1024 * 1024 * 3), '3.0 MB');
    });

    test('速率为零时不显示数字', () {
      expect(Format.speed(0), '—');
      expect(Format.speed(1024), '1.0 KB/s');
    });

    test('相对时间落在可读区间', () {
      final DateTime now = DateTime.now();
      expect(Format.relative(now), '刚刚');
      expect(Format.relative(now.subtract(const Duration(minutes: 5))), '5 分钟前');
    });
  });

  group('协议解析', () {
    test('能读懂 v2.2 的设备信息', () {
      final WispDevice device = WispDevice.fromJson(<String, dynamic>{
        'alias': 'Secret Banana',
        'version': '2.2',
        'deviceModel': 'Windows',
        'deviceType': 'desktop',
        'fingerprint': 'abcdef0123456789',
        'port': 53317,
        'protocol': 'https',
        'download': true,
      }, ip: '192.168.1.8');

      expect(device.alias, 'Secret Banana');
      expect(device.kind, DeviceKind.desktop);
      expect(device.baseUrl, 'https://192.168.1.8:53317');
      expect(device.shortFingerprint, 'ABCDEF01');
    });

    test('未知设备类型回落到 unknown', () {
      final WispDevice device = WispDevice.fromJson(
        <String, dynamic>{'alias': 'X', 'deviceType': 'toaster'},
        ip: '10.0.0.2',
      );
      expect(device.kind, DeviceKind.unknown);
      expect(device.baseUrl, 'https://10.0.0.2:53317');
    });

    test('会话进度与速率不会越界', () {
      final TransferSession session = TransferSession(
        id: 's1',
        peerAlias: 'Peer',
        peerIp: '10.0.0.3',
        direction: TransferDirection.outgoing,
        files: <TransferFile>[
          TransferFile(id: 'f1', name: 'a.bin', size: 100),
        ],
      );
      expect(session.progress, 0);
      session.files.first.sent = 50;
      expect(session.progress, closeTo(0.5, 0.001));
      session.files.first.sent = 200;
      expect(session.progress, 1);
    });
  });

  group('界面渲染', () {
    testWidgets('联系人页在无联系人时显示空态', (WidgetTester tester) async {
      await tester.pumpWidget(host(const ContactsPage()));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('联系人'), findsOneWidget);
      expect(find.text('还没有联系人'), findsOneWidget);
      expect(find.textContaining('选一台附近的设备'), findsOneWidget);
    });

    testWidgets('发送页空态给出三个入口', (WidgetTester tester) async {
      await tester.pumpWidget(host(const SendPage()));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('发送'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);
      expect(find.text('文件夹'), findsOneWidget);
      expect(find.text('文字'), findsOneWidget);
      expect(find.text('附近没有可用设备'), findsOneWidget);
    });

    testWidgets('设备行显示名称与地址', (WidgetTester tester) async {
      final WispDevice device = WispDevice.fromJson(<String, dynamic>{
        'alias': '书房 iMac',
        'deviceType': 'desktop',
        'deviceModel': 'macOS',
      }, ip: '192.168.1.12');

      await tester.pumpWidget(host(DeviceTile(device: device, onTap: () {})));
      expect(find.text('书房 iMac'), findsOneWidget);
      expect(find.textContaining('192.168.1.12'), findsOneWidget);
    });

    testWidgets('传输页显示进度与文件', (WidgetTester tester) async {
      final TransferSession session = TransferSession(
        id: 's2',
        peerAlias: 'Tyler 的 iPhone',
        peerIp: '192.168.1.31',
        direction: TransferDirection.outgoing,
        files: <TransferFile>[
          TransferFile(id: 'f1', name: '海边日落.jpg', size: 4404019),
          TransferFile(id: 'f2', name: '产品方案.pdf', size: 19293798),
        ],
      );
      session.files.first.sent = 4404019;
      session.status = TransferStatus.active;

      await tester.pumpWidget(host(TransferPage(session: session)));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Tyler 的 iPhone'), findsOneWidget);
      expect(find.text('传输中'), findsOneWidget);
      expect(find.text('海边日落.jpg'), findsOneWidget);
      expect(find.text('取消传输'), findsOneWidget);
    });
  });

  test('浅色/深色主题都能构建', () {
    expect(WispTheme.light().brightness, Brightness.light);
    expect(WispTheme.dark().brightness, Brightness.dark);
    expect(WispTheme.light().textTheme.displayLarge?.fontSize, 34);
  });
}
