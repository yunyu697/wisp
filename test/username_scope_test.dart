// 「识别用户名」的可见性规则：同名才互相可见。
//
// 这条规则必须在两头发力，只做界面过滤是不够的：
// · 我这边：用户名对不上的设备不进列表（AppState 兜底，发现层先拦一道）；
// · 对方那边：用户名对不上时**连响应都不给**，否则对方扫一遍网段，
//   凭一个 200 就知道我们在，照样把我们画进列表。
//
// 空对空算同名（都没启用），空对非空算不同——这就是"设了用户名之后
// 不被没设的人看到"的实现方式。
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/core/username_scope.dart';
import 'package:wisp/services/discovery_service.dart';
import 'package:wisp/models/transfer.dart';
import 'package:wisp/models/message.dart';
import 'package:wisp/services/receiver_service.dart';
import 'package:wisp/services/settings_service.dart';

/// 发一个 POST 并读回响应。放独立 isolate：主 isolate 的 HttpClient 是桩。
Future<({int status, String body})> _post(String url, Map<String, dynamic> payload) {
  return Isolate.run(() async {
    final HttpClient client = HttpClient()
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    try {
      final HttpClientRequest request = await client.postUrl(Uri.parse(url));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
      final HttpClientResponse response = await request.close();
      final String body = await response.transform(utf8.decoder).join();
      return (status: response.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  });
}

Map<String, dynamic> _info(String username) => <String, dynamic>{
      'alias': '对端',
      'version': '2.2',
      'deviceModel': 'test',
      'deviceType': 'desktop',
      'fingerprint': 'peer-fp-$username',
      'port': 53317,
      'protocol': 'http',
      if (username.isNotEmpty) 'username': username,
    };

/// 起一个接收端，返回它的 baseUrl。调用方负责 stop。
Future<({ReceiverService service, String base})> _startReceiver(String username) async {
  final ReceiverService service = ReceiverService(
    settings: WispSettings(
      alias: '本机',
      fingerprint: 'self-fp',
      username: username,
      encryption: false,
      port: 0,
    ),
    onIncoming: (IncomingRequest request) async => const ReceiveDecision.accept(),
    onProgress: (TransferSession session) {},
    onFinished: (TransferSession session) {},
    onLog: (String message) {},
    onMessage: (IncomingMessage message) {},
  );
  await service.start();
  return (service: service, base: 'http://127.0.0.1:${service.boundPort}');
}

/// 以 [username] 的身份扫描 127.0.0.1:[port]，返回发现到的设备别名。
///
/// 必须是顶层函数：闭包会把外层作用域整个塞进 isolate 消息，
/// 里面的 HttpServer 不可发送。
Future<List<String>> _probeAs(int port, String username) {
  return Isolate.run(() async {
    final List<String> aliases = <String>[];
    final DiscoveryService discovery = DiscoveryService(
      settings: WispSettings(
        alias: '探测方',
        fingerprint: 'probe-fp',
        username: username,
        port: port,
      ),
      onDevice: (device) => aliases.add(device.alias),
      onError: (String message) {},
      secure: false,
    );
    await discovery.probeAddress('127.0.0.1');
    await discovery.dispose();
    return aliases;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('规则本身', () {
    test('去掉首尾空白、忽略大小写', () {
      expect(normalizeUsername('  ZhangSan '), 'zhangsan');
      expect(sameUsernameScope('ZhangSan', 'zhangsan'), isTrue);
      expect(sameUsernameScope(' zhangsan ', 'zhangsan'), isTrue);
      expect(sameUsernameScope('zhangsan', 'lisi'), isFalse);
    });

    test('空对空算同名，空对非空算不同', () {
      expect(sameUsernameScope('', ''), isTrue);
      expect(sameUsernameScope('   ', ''), isTrue);
      // 关键：我设了、对方没设 → 互相不可见。
      expect(sameUsernameScope('team', ''), isFalse);
      expect(sameUsernameScope('', 'team'), isFalse);
    });
  });

  group('接收端 /register', () {
    test('用户名相同才回设备信息，不同直接 403', () async {
      final ({ReceiverService service, String base}) r = await _startReceiver('team');
      addTearDown(r.service.stop);

      final ({int status, String body}) same =
          await _post('${r.base}/api/localsend/v2/register', _info('team'));
      expect(same.status, 200, reason: '同名用户应当能发现我们');
      expect(same.body, contains('本机'));

      final ({int status, String body}) other =
          await _post('${r.base}/api/localsend/v2/register', _info('other'));
      expect(other.status, 403, reason: '不同用户名的设备不该拿到我们的信息');
      expect(other.body, isNot(contains('本机')));

      // 对方没设用户名：我们设了 → 也算不同。
      final ({int status, String body}) anon =
          await _post('${r.base}/api/localsend/v2/register', _info(''));
      expect(anon.status, 403, reason: '我们设了用户名，没设的设备不该看得到我们');
    });

    test('本机没设用户名时，只回应同样没设的设备', () async {
      final ({ReceiverService service, String base}) r = await _startReceiver('');
      addTearDown(r.service.stop);

      final ({int status, String body}) anon =
          await _post('${r.base}/api/localsend/v2/register', _info(''));
      expect(anon.status, 200);

      final ({int status, String body}) named =
          await _post('${r.base}/api/localsend/v2/register', _info('team'));
      expect(named.status, 403, reason: '设了用户名的设备会互相隐藏，我们看不到它，它也不该看到我们');
    });
  });

  group('接收端 /prepare-upload', () {
    test('用户名不一致时拒绝传输，哪怕对方直接拿着 IP 来推', () async {
      final ({ReceiverService service, String base}) r = await _startReceiver('team');
      addTearDown(r.service.stop);

      Map<String, dynamic> body(String username) => <String, dynamic>{
            'info': _info(username),
            'files': <String, dynamic>{
              'f1': <String, dynamic>{
                'id': 'f1',
                'fileName': 'a.txt',
                'size': 3,
                'fileType': 'text/plain',
              },
            },
          };

      final ({int status, String body}) other = await _post(
          '${r.base}/api/localsend/v2/prepare-upload', body('other'));
      expect(other.status, 403, reason: '不同用户名不该能发起传输：${other.body}');

      final ({int status, String body}) same = await _post(
          '${r.base}/api/localsend/v2/prepare-upload', body('team'));
      expect(same.status, 200, reason: '同名用户应当被放行：${same.body}');
    });
  });

  group('发现链路', () {
    // 注意：探测会把默认端口 53317 也试一遍，本机若正跑着 Wisp 就会顺带发现它。
    // 所以只断言"我们这台在不在"，不断言"列表里只有它"。
    test('只有同用户名的设备会出现在列表里', () async {
      final ({ReceiverService service, String base}) r = await _startReceiver('team');
      addTearDown(r.service.stop);

      expect(await _probeAs(r.service.boundPort!, 'team'), contains('本机'));
      expect(await _probeAs(r.service.boundPort!, 'other'), isNot(contains('本机')),
          reason: '用户名不同，扫到也不该进列表');
      expect(await _probeAs(r.service.boundPort!, ''), isNot(contains('本机')),
          reason: '我们设了用户名，没设的设备不该看到我们');
    });

    test('本机没设用户名时，看得到同样没设的设备，看不到设了的', () async {
      final ({ReceiverService service, String base}) r = await _startReceiver('');
      addTearDown(r.service.stop);

      expect(await _probeAs(r.service.boundPort!, ''), contains('本机'));
      expect(await _probeAs(r.service.boundPort!, 'team'), isNot(contains('本机')));
    });
  });
}
