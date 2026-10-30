import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wisp/models/device.dart';
import 'package:wisp/models/transfer.dart';
import 'package:wisp/services/sender_service.dart';

/// 发送方在 prepare-upload 里自报的 info 必须如实反映本机状态。
///
/// 曾经写死 `port: 53317, protocol: 'https'`：改过端口的实例（为了和官方
/// 客户端同机共存）会告诉对端错误端口，没证书的实例会告诉对端走 https，
/// 结果对端回连一律失败。这两个字段现在必须来自设置。
void main() {
  late HttpServer server;
  late Map<String, dynamic> received;

  setUp(() async {
    received = <String, dynamic>{};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final String body = await utf8.decoder.bind(request).join();
      received = jsonDecode(body) as Map<String, dynamic>;
      request.response
        ..statusCode = 204
        ..close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Future<Map<String, dynamic>> sendInfo({required int port, required bool secure}) async {
    final SenderService sender = SenderService(
      alias: 'Tester',
      fingerprint: 'fp-test',
      deviceKind: 'desktop',
      port: port,
      secure: secure,
    );
    final WispDevice device = WispDevice(
      alias: 'Peer',
      ip: '127.0.0.1',
      fingerprint: 'fp-peer',
      port: server.port,
      https: false,
    );
    final TransferSession session = TransferSession(
      id: 's1',
      peerAlias: 'Peer',
      peerIp: '127.0.0.1',
      direction: TransferDirection.outgoing,
      files: <TransferFile>[
        TransferFile(id: 'f1', name: 'a.txt', size: 3),
      ],
    );
    await sender.prepare(session, device);
    return received['info'] as Map<String, dynamic>;
  }

  test('自定义端口与 HTTP 协议如实上报', () async {
    final Map<String, dynamic> info = await sendInfo(port: 53318, secure: false);
    expect(info['port'], 53318);
    expect(info['protocol'], 'http');
  });

  test('默认端口与 HTTPS 协议如实上报', () async {
    final Map<String, dynamic> info = await sendInfo(port: 53317, secure: true);
    expect(info['port'], 53317);
    expect(info['protocol'], 'https');
  });
}
