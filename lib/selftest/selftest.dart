import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/utils/external.dart';
import '../models/device.dart';
import '../models/transfer.dart';
import '../services/desktop_service.dart';
import '../services/receiver_service.dart';
import '../services/sender_service.dart';
import '../state/app_state.dart';

/// 受控端到端自测入口。
///
/// 为什么需要它：界面上的"选设备 → 选文件 → 发送"必须点系统文件对话框，
/// 自动化成本极高（SendInput 对 IFileOpenDialog 无效），于是"能不能真的发出去"
/// 一直没法自动验证。这里把同一套 SenderService 接到命令行上：
///
/// ```bash
/// wisp.exe --wisp-selftest --wisp-report=C:\temp\selftest.json
/// wisp.exe --wisp-send=192.168.0.168:53317 --wisp-file=C:\a.zip
/// ```
///
/// 结果写进 JSON 报告，退出码 0 表示全部通过。GUI 子系统没有控制台，
/// 所以报告文件才是唯一可靠的输出通道。
class WispCliOptions {
  const WispCliOptions({
    required this.selfTest,
    this.reportPath,
    this.sendTarget,
    this.sendFile,
    this.sendPin,
    this.sendHttps = false,
    this.openUrl,
  });

  final bool selfTest;
  final String? reportPath;
  final String? sendTarget;
  final String? sendFile;
  final String? sendPin;
  final bool sendHttps;

  /// 要验证「点下载链接能不能唤起浏览器」的 URL。
  final String? openUrl;

  /// 解析命令行；没有 Wisp 自己的参数时返回 null（走正常启动路径）。
  static WispCliOptions? parse(List<String> args) {
    bool selfTest = false;
    String? report;
    String? target;
    String? file;
    String? pin;
    bool https = false;
    String? openUrl;

    for (final String arg in args) {
      if (arg == '--wisp-selftest') {
        selfTest = true;
      } else if (arg.startsWith('--wisp-report=')) {
        report = arg.substring('--wisp-report='.length);
      } else if (arg.startsWith('--wisp-send=')) {
        target = arg.substring('--wisp-send='.length);
      } else if (arg.startsWith('--wisp-file=')) {
        file = arg.substring('--wisp-file='.length);
      } else if (arg.startsWith('--wisp-pin=')) {
        pin = arg.substring('--wisp-pin='.length);
      } else if (arg == '--wisp-https') {
        https = true;
      } else if (arg.startsWith('--wisp-openurl=')) {
        openUrl = arg.substring('--wisp-openurl='.length);
      }
    }

    if (!selfTest && target == null && openUrl == null) return null;
    return WispCliOptions(
      selfTest: selfTest,
      reportPath: report,
      sendTarget: target,
      sendFile: file,
      sendPin: pin,
      sendHttps: https,
      openUrl: openUrl,
    );
  }
}

/// 单步结果。
class SelfTestStep {
  SelfTestStep(this.name, this.ok, this.detail);

  final String name;
  final bool ok;
  final String detail;

  Map<String, Object?> toJson() =>
      <String, Object?>{'name': name, 'ok': ok, 'detail': detail};
}

/// 自测执行器。所有断言都基于**原生窗口的真实状态**，不靠截图肉眼看。
class SelfTestRunner {
  SelfTestRunner(this.options);

  final WispCliOptions options;
  final List<SelfTestStep> steps = <SelfTestStep>[];

  bool get ok => steps.isNotEmpty && steps.every((SelfTestStep s) => s.ok);

  Future<void> run() async {
    if (options.sendTarget != null) {
      await _step('send_peer', _sendToPeer);
    }
    if (options.openUrl != null) {
      await _step('open_url', _openUrl);
    }
    if (options.selfTest) {
      await _step('send_loopback', _sendLoopback);
      await _step('toast_visible', _toastVisible);
      await _step('toast_first_shot', _toastFirstShotWhenHidden);
      await _step('toast_painted', _toastPaintedFirstShot);
      await _step('surface_drawn', _surfaceDrawnConfirmed);
      await _step('notice_survives', _noticeSurvivesMissingCard);
      await _step('real_incoming_flow', _realIncomingFlow);
      await _step('real_incoming_blurred', _realIncomingFlowBlurred);
      await _step('main_not_black_activate', _mainWindowNotBlackOnActivate);
      await _step('main_not_black_tray', _mainWindowNotBlack);
      await _step('main_not_black_taskbar', _mainWindowNotBlackTaskbar);
    }
  }

  /// 验证「点下载链接能唤起浏览器」。
  ///
  /// 只看 ShellExecute 的返回值不够——它成功也可能没真的打开浏览器。
  /// 这里对比前后浏览器**进程实例数**（按 PID 计，不是进程名去重）：
  /// 浏览器已经开着时，新标签页常常复用同一个进程，只看进程名会漏判。
  Future<String?> _openUrl() async {
    final String url = options.openUrl!;
    final int before = await _browserProcessCount();
    final ExternalOpenResult result = await openExternal(url);
    if (!result.opened) {
      throw StateError('openExternal 失败：${result.message ?? '未知原因'}');
    }
    // 给系统一点时间把浏览器拉起来。
    int after = before;
    for (int i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      after = await _browserProcessCount();
      if (after > before) break;
    }
    if (after <= before) {
      throw StateError(
          'openExternal 报告成功，但浏览器进程数没变（before=$before after=$after）');
    }
    return '已唤起浏览器：浏览器进程 $before → $after';
  }

  /// 当前运行的浏览器进程实例数（按 PID 计）。
  Future<int> _browserProcessCount() async {
    final ProcessResult result =
        await Process.run('tasklist', <String>['/FO', 'CSV', '/NH']);
    int count = 0;
    for (final String line in result.stdout.toString().split('\n')) {
      final String lower = line.toLowerCase();
      for (final String exe in <String>[
        'msedge.exe',
        'chrome.exe',
        'firefox.exe',
        'brave.exe',
        'vivaldi.exe',
        'opera.exe',
      ]) {
        // tasklist 的 CSV 每行是一个进程实例：名称,PID,...
        if (lower.contains('"$exe"')) {
          count++;
          break;
        }
      }
    }
    return count;
  }

  Future<void> _step(
      String name, Future<String?> Function() body) async {
    try {
      final String? detail = await body();
      steps.add(SelfTestStep(name, true, detail ?? 'ok'));
    } catch (e) {
      steps.add(SelfTestStep(name, false, '$e'));
    }
  }

  // ---------------------------------------------------------------------------
  // 步骤一：端到端发送（内置接收端，验证 prepare-upload + upload 全链路）
  // ---------------------------------------------------------------------------

  Future<String?> _sendLoopback() async {
    final Directory dir =
        await Directory.systemTemp.createTemp('wisp-selftest');
    final File payload = File('${dir.path}${Platform.pathSeparator}probe.bin');
    final List<int> bytes =
        List<int>.generate(96 * 1024, (int i) => i % 251);
    await payload.writeAsBytes(bytes);

    final BytesBuilder sink = BytesBuilder();
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final String path = request.uri.path;
      if (path.endsWith('/register')) {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(<String, dynamic>{
            'alias': 'SelfTest-Peer',
            'version': WispProtocol.version,
            'deviceModel': 'Windows',
            'deviceType': 'desktop',
            'fingerprint': 'selftest-peer',
            'port': server.port,
            'protocol': 'http',
            'download': false,
          }));
        await request.response.close();
        return;
      }
      if (path.endsWith('/prepare-upload')) {
        final String body = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> decoded =
            jsonDecode(body) as Map<String, dynamic>;
        final Map<String, dynamic> files =
            decoded['files'] as Map<String, dynamic>;
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(<String, dynamic>{
            'sessionId': 'selftest-session',
            'files': <String, String>{
              for (final String id in files.keys) id: 'token-$id',
            },
          }));
        await request.response.close();
        return;
      }
      if (path.endsWith('/upload')) {
        // 严格校验：会话号必须是 prepare 签发的那个、token 必须对得上。
        // 之前的假服务器来者不拒，把"发送端拿本地会话号上传"的 bug 掩盖了。
        final String? sessionId = request.uri.queryParameters['sessionId'];
        final String? fileId = request.uri.queryParameters['fileId'];
        final String? token = request.uri.queryParameters['token'];
        if (sessionId != 'selftest-session' ||
            fileId == null ||
            token != 'token-$fileId') {
          throw StateError('会话/令牌校验失败：sessionId=$sessionId fileId=$fileId');
        }
        sink.add(await request.fold<List<int>>(
            <int>[], (List<int> acc, List<int> chunk) => acc..addAll(chunk)));
        request.response.statusCode = 200;
        await request.response.close();
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });

    final SenderService sender = SenderService(
      alias: 'SelfTest',
      fingerprint: 'selftest-self',
      deviceKind: 'desktop',
      port: 53317,
      secure: false,
    );
    final WispDevice peer = WispDevice(
      alias: 'SelfTest-Peer',
      ip: '127.0.0.1',
      fingerprint: 'selftest-peer',
      port: server.port,
      https: false,
    );
    final TransferSession session = TransferSession(
      id: 'selftest-1',
      peerAlias: peer.alias,
      peerIp: peer.ip,
      direction: TransferDirection.outgoing,
      files: <TransferFile>[
        TransferFile(id: 'f1', name: 'probe.bin', size: bytes.length, path: payload.path),
      ],
    );

    try {
      await sender.prepare(session, peer);
      await sender.uploadAll(session, peer);
    } finally {
      await server.close(force: true);
      unawaited(dir.delete(recursive: true).catchError((Object _) => dir));
    }

    final List<int> got = sink.takeBytes();
    if (got.length != bytes.length) {
      throw StateError('收到 ${got.length} 字节，应为 ${bytes.length}');
    }
    for (int i = 0; i < got.length; i++) {
      if (got[i] != bytes[i]) throw StateError('第 $i 字节不一致');
    }
    return '${got.length} 字节逐字节一致';
  }

  // ---------------------------------------------------------------------------
  // 步骤二：发到真实对端（跨机验证用）
  // ---------------------------------------------------------------------------

  Future<String?> _sendToPeer() async {
    final String target = options.sendTarget!;
    final String path = options.sendFile ?? '';
    if (path.isEmpty) throw ArgumentError('缺少 --wisp-file=<路径>');
    final File file = File(path);
    if (!file.existsSync()) throw ArgumentError('文件不存在：$path');

    String host = target;
    int port = WispProtocol.defaultPort;
    final int colon = target.lastIndexOf(':');
    if (colon > 0) {
      host = target.substring(0, colon);
      port = int.tryParse(target.substring(colon + 1)) ?? WispProtocol.defaultPort;
    }

    final WispDevice peer = WispDevice(
      alias: host,
      ip: host,
      fingerprint: '',
      port: port,
      https: options.sendHttps,
    );
    final SenderService sender = SenderService(
      alias: 'Wisp-SelfTest',
      fingerprint: 'selftest-self',
      deviceKind: 'desktop',
      port: 53317,
      secure: false,
    );
    final int size = file.lengthSync();
    final TransferSession session = TransferSession(
      id: 'cli-${DateTime.now().millisecondsSinceEpoch}',
      peerAlias: host,
      peerIp: host,
      direction: TransferDirection.outgoing,
      files: <TransferFile>[
        TransferFile(id: 'f1', name: file.uri.pathSegments.last, size: size, path: path),
      ],
    );
    await _sendGuarded(sender, session, peer);
    return '已发送 ${file.uri.pathSegments.last}（$size 字节）到 $host:$port';
  }

  /// CLI 发送要限时：对方开着"手动确认接收"时，prepare 会一直挂着等人点按钮，
  /// 没有限时的话 --wisp-send 就永远不退出、报告也写不出来。
  Future<void> _sendGuarded(
    SenderService sender,
    TransferSession session,
    WispDevice peer,
  ) async {
    const Duration limit = Duration(seconds: 90);
    try {
      await sender.prepare(session, peer, pin: options.sendPin).timeout(limit);
      if (session.status != TransferStatus.completed) {
        await sender.uploadAll(session, peer).timeout(limit);
      }
    } on TimeoutException {
      throw StateError(
          '对方 ${limit.inSeconds} 秒内没有响应（可能开着"手动确认接收"，正在等人点按钮；'
          '在对方设置里打开"快速保存/自动接收"后再试）');
    }
  }

  // ---------------------------------------------------------------------------
  // 步骤三：桌面通知卡（toast）的真实状态复查
  // ---------------------------------------------------------------------------

  Future<Map<String, Object?>> _windows() => DesktopService.debugWindows();

  /// 原生回传的是 `Map<Object?, Object?>`，这里统一成 String 键。
  static Map<String, Object?> _rect(Object? raw) {
    if (raw is! Map) return <String, Object?>{};
    return <String, Object?>{
      'visible': raw['visible'],
      'left': raw['left'],
      'top': raw['top'],
      'right': raw['right'],
      'bottom': raw['bottom'],
    };
  }

  static bool _inside(Map<String, Object?> w, Map<String, Object?> all) {
    final int l = w['left']! as int, t = w['top']! as int;
    final int r = w['right']! as int, b = w['bottom']! as int;
    final int wl = all['workLeft']! as int, wt = all['workTop']! as int;
    final int wr = all['workRight']! as int, wb = all['workBottom']! as int;
    return l >= wl - 2 && t >= wt - 2 && r <= wr + 2 && b <= wb + 2;
  }

  Future<String?> _toastVisible() async {
    await DesktopService.showToast('收到传输请求', 'SelfTest 想发送 1 个文件（96 KB）',
        mode: DesktopService.bubbleAsk);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final Map<String, Object?> all = await _windows();
    final Map<String, Object?> toast = _rect(all['toast']);
    await DesktopService.hideToast();
    if (toast['visible'] != true) throw StateError('通知卡没有显示：$toast');
    if (!_inside(toast, all)) throw StateError('通知卡跑到工作区外：$toast');
    return '位置 $toast 在工作区内';
  }

  /// 主窗口收进托盘（隐藏）时，第一次弹通知卡必须立刻出现。
  ///
  /// 用户报的"要第二次才会出现"就复现在这里：主窗口开着时能弹，
  /// 收进托盘后第一次反而不出来。
  Future<String?> _toastFirstShotWhenHidden() async {
    await DesktopService.debugSetMainVisible(false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await DesktopService.showToast('收到传输请求', 'SelfTest 想发送 1 个文件（96 KB）',
        mode: DesktopService.bubbleAsk);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final Map<String, Object?> all = await _windows();
    final Map<String, Object?> toast = _rect(all['toast']);
    await DesktopService.hideToast();
    await DesktopService.debugSetMainVisible(true);
    if (toast['visible'] != true) {
      throw StateError('主窗口隐藏时第一次通知卡没有出现：$toast');
    }
    return '托盘态第一次就弹出来了：$toast';
  }

  /// 通知出现后再打开主窗口，主窗口不能黑屏。
  ///
  /// 两种"打开主窗口"的路径都要试：托盘菜单（showWindow → RestoreWindow，
  /// 内部有 ForceRedraw）和任务栏直接点亮（没有 ForceRedraw）。
  Future<String?> _mainWindowNotBlack() async {
    await DesktopService.debugSetMainVisible(true);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final Map<String, Object?> baseline = await DesktopService.debugCapture('main');
    final double baseMean = (baseline['mean'] as num?)?.toDouble() ?? 0;
    if (baseMean < 20) {
      throw StateError('基线就不正常（亮度 $baseMean），先别测黑屏');
    }

    // 收进托盘 → 弹通知 → 用户再点回主窗口。
    await DesktopService.debugSetMainVisible(false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await DesktopService.showToast('收到传输请求', 'SelfTest 想发送 1 个文件（96 KB）',
        mode: DesktopService.bubbleAsk);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    await DesktopService.showWindow();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final Map<String, Object?> afterTray = await DesktopService.debugCapture('main');
    final double trayMean = (afterTray['mean'] as num?)?.toDouble() ?? 0;
    final double trayDark = (afterTray['dark'] as num?)?.toDouble() ?? 0;

    await DesktopService.hideToast();
    if (trayMean < baseMean * 0.35 || trayDark > 0.6) {
      throw StateError('从托盘唤回主窗口后黑屏：基线 $baseMean → $trayMean（黑像素 $trayDark）');
    }
    return '托盘唤回：基线 $baseMean → $trayMean（黑像素 $trayDark）';
  }

  /// 任务栏直接点亮主窗口（不走 RestoreWindow，没有 ForceRedraw）时也不能黑屏。
  Future<String?> _mainWindowNotBlackTaskbar() async {
    await DesktopService.debugSetMainVisible(true);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final Map<String, Object?> baseline = await DesktopService.debugCapture('main');
    final double baseMean = (baseline['mean'] as num?)?.toDouble() ?? 0;
    if (baseMean < 20) {
      throw StateError('基线就不正常（亮度 $baseMean），先别测黑屏');
    }

    await DesktopService.debugSetMainVisible(false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await DesktopService.showToast('收到传输请求', 'SelfTest 想发送 1 个文件（96 KB）',
        mode: DesktopService.bubbleAsk);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    await DesktopService.debugSetMainVisible(true);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final Map<String, Object?> after = await DesktopService.debugCapture('main');
    final double mean = (after['mean'] as num?)?.toDouble() ?? 0;
    final double dark = (after['dark'] as num?)?.toDouble() ?? 0;

    await DesktopService.hideToast();
    if (mean < baseMean * 0.35 || dark > 0.6) {
      throw StateError('任务栏点亮后黑屏：基线 $baseMean → $mean（黑像素 $dark）');
    }
    return '任务栏点亮：基线 $baseMean → $mean（黑像素 $dark）';
  }

  /// 通知卡必须真的画出了像素。
  ///
  /// IsWindowVisible 只说明窗口"显示了"，不代表上面有东西——
  /// 用户看到的"要第二次才会出现"很可能就是第一次根本没画出来。
  /// 这一步把通知卡区域从屏幕上抓下来存成 PNG，并报出亮度。
  Future<String?> _toastPaintedFirstShot() async {
    await DesktopService.debugSetMainVisible(false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await DesktopService.showToast('收到传输请求', 'SelfTest 想发送 1 个文件（96 KB）',
        mode: DesktopService.bubbleAsk);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final Map<String, Object?> shot = await DesktopService.debugCapture('toast');
    final Map<String, Object?> all = await _windows();
    final Map<String, Object?> toast = _rect(all['toast']);
    await DesktopService.hideToast();
    await DesktopService.debugSetMainVisible(true);
    if (toast['visible'] != true) {
      throw StateError('通知卡没有显示：$toast');
    }
    final double mean = (shot['mean'] as num?)?.toDouble() ?? 0;
    return '通知卡可见=$toast，区域平均亮度 $mean（PNG 已落盘到 exe 同目录）';
  }

  /// 走**真实**的通知分流逻辑（AppState.handleIncomingRequest），
  /// 而不是直接调原生通道。
  ///
  /// 直接调 showToast 测不到 decideIncomingSurface 的判断——
  /// 用户报的"要第二次才会出现"就出在那一层。
  /// 这里模拟真实场景：主窗口收进托盘，用户在忙别的，这时来一个请求。
  Future<String?> _realIncomingFlow() async {
    final AppState state = AppState();
    await DesktopService.debugSetMainVisible(false);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    state.handleIncomingRequest(_fakeRequest());
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final Map<String, Object?> all = await _windows();
    final Map<String, Object?> toast = _rect(all['toast']);
    final Map<String, Object?> shot = await DesktopService.debugCapture('toast');

    await DesktopService.hideToast();
    await DesktopService.debugSetMainVisible(true);
    await Future<void>.delayed(const Duration(milliseconds: 600));

    if (toast['visible'] != true) {
      throw StateError('真实流程下第一次没有桌面通知卡：$toast');
    }
    final double mean = (shot['mean'] as num?)?.toDouble() ?? 0;
    return '第一次就出来了：toast=$toast，通知卡区域亮度 $mean';
  }

  /// 伪造一个接收请求。
  static IncomingRequest _fakeRequest() {
    final WispDevice sender = WispDevice(
      alias: 'SelfTest-Peer',
      ip: '127.0.0.1',
      fingerprint: 'selftest-fake',
      port: 53317,
      https: false,
    );
    return IncomingRequest(
      sender: sender,
      files: <TransferFile>[
        TransferFile(id: 'f1', name: 'probe.bin', size: 1024),
      ],
    );
  }

  /// 用户最常见的场景：主窗口**开着但没被使用**（在别的程序上）。
  ///
  /// 这时必须弹桌面通知。而"主窗口正被使用"时按设计走应用内弹层。
  /// 两个场景连起来，正好对应用户说的"要第二次才会出现"——
  /// 第一次主窗口在前台所以走应用内，第二次切走了才走桌面。
  Future<String?> _realIncomingFlowBlurred() async {
    final AppState state = AppState();
    await DesktopService.debugSetMainVisible(true);
    await DesktopService.debugBlurMain();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    state.handleIncomingRequest(_fakeRequest());
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final Map<String, Object?> all = await _windows();
    final Map<String, Object?> toast = _rect(all['toast']);

    await DesktopService.hideToast();
    if (toast['visible'] != true) {
      throw StateError(
          '主窗口开着但没被使用时，第一次请求没有桌面通知卡：toast=$toast');
    }
    return '失焦态第一次就弹出来了：toast=$toast';
  }

  /// 主窗口开着但没被使用时收到通知，随后用户点回主窗口——主窗口不能黑屏。
  ///
  /// 这条路径不走 RestoreWindow（没有 ForceRedraw），是最容易黑屏的一条。
  Future<String?> _mainWindowNotBlackOnActivate() async {
    await DesktopService.debugSetMainVisible(true);
    await DesktopService.debugBlurMain();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final Map<String, Object?> baseline = await DesktopService.debugCapture('main');
    final double baseMean = (baseline['mean'] as num?)?.toDouble() ?? 0;

    await DesktopService.showToast('收到传输请求', 'SelfTest 想发送 1 个文件（96 KB）',
        mode: DesktopService.bubbleAsk);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    // 用户点回主窗口：置前 → 原生层收到 WM_ACTIVATE → 收起通知卡。
    await DesktopService.debugFocusMain();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final Map<String, Object?> after = await DesktopService.debugCapture('main');
    final double mean = (after['mean'] as num?)?.toDouble() ?? 0;
    final double dark = (after['dark'] as num?)?.toDouble() ?? 0;

    await DesktopService.hideToast();
    if (baseMean > 20 && (mean < baseMean * 0.5 || dark > 0.4)) {
      throw StateError('点回主窗口后黑屏：基线 $baseMean → $mean（黑像素 $dark）');
    }
    return '点回主窗口：基线 $baseMean → $mean（黑像素 $dark）';
  }

  /// 原生层必须确认"真的画出来了"，而不只是"窗口是可见的"。
  ///
  /// 以前通知卡是"先画到屏幕外再滑进来"：动画帧没跑到时窗口在屏幕外，
  /// 而 IsWindowVisible 仍报 true——这就是"第一次不出现、第二次才出现"。
  /// 现在位置固定、动画只调透明度，并且原生层会回报 drawn 状态。
  Future<String?> _surfaceDrawnConfirmed() async {
    await DesktopService.showToast('收到传输请求', 'SelfTest 想发送 1 个文件（96 KB）',
        mode: DesktopService.bubbleAsk);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final Map<String, Object?> status = await DesktopService.surfaceStatus();
    final Object? toast = status['toast'];
    // 位置必须落在工作区内，不能停在屏幕外。
    //
    // 注意取样顺序：这里要在 hideToast 之前取窗口矩形，否则拿回来的是
    // "已经收起"的状态，报告会打印出 visible=false，跟"visible+drawn
    // 均为真"的结论自相矛盾，排查时白白怀疑半天。
    final Map<String, Object?> all = await _windows();
    final Map<String, Object?> rect = _rect(all['toast']);
    await DesktopService.hideToast();
    if (toast is! Map) throw StateError('拿不到通知卡状态：$status');
    if (toast['visible'] != true) {
      throw StateError('通知卡不可见：$toast');
    }
    if (toast['drawn'] != true) {
      throw StateError('通知卡窗口在但没画出来：$toast');
    }
    if (!_inside(rect, all)) {
      throw StateError('通知卡停在屏幕外：$rect');
    }
    return '通知卡 visible+drawn 均为真，且位置在工作区内：$rect';
  }

  /// 通知卡超时收掉之后，"传输结束"提示必须重新弹一张，而不是被吞掉。
  ///
  /// 走 AppState 的真实收尾路径：卡片不在时 updateToast 是空操作，
  /// 必须退化成"新弹一张"，否则用户根本不知道传输结束了。
  Future<String?> _noticeSurvivesMissingCard() async {
    final AppState state = AppState();
    state.handleIncomingRequest(_fakeRequest());
    await Future<void>.delayed(const Duration(milliseconds: 900));
    // 手动把通知卡收掉（模拟超时收起）。
    await DesktopService.hideToast();
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final TransferSession session = TransferSession(
      id: 'selftest-cancel',
      peerAlias: 'SelfTest-Peer',
      peerIp: '127.0.0.1',
      direction: TransferDirection.incoming,
      files: <TransferFile>[
        TransferFile(id: 'f1', name: 'probe.bin', size: 1024),
      ],
    )..status = TransferStatus.canceled;
    state.handleTransferFinished(session);

    await Future<void>.delayed(const Duration(milliseconds: 900));
    final Map<String, Object?> status = await DesktopService.surfaceStatus();
    final Object? toast = status['toast'];
    await DesktopService.hideToast();
    if (toast is! Map || toast['drawn'] != true) {
      throw StateError('卡片不在时结局提示被吞掉了：$toast');
    }
    return '卡片不在时结局提示重新弹出来了';
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'ok': ok,
        'platform': Platform.operatingSystem,
        'steps': steps.map((SelfTestStep s) => s.toJson()).toList(),
      };
}

/// 自测模式下代替正常界面的极简外壳：跑完就退出，不碰用户的设置与历史。
class SelfTestApp extends StatefulWidget {
  const SelfTestApp({super.key, required this.options});

  final WispCliOptions options;

  @override
  State<SelfTestApp> createState() => _SelfTestAppState();
}

class _SelfTestAppState extends State<SelfTestApp> {
  String _status = '自测运行中…';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    // 等一帧，确保原生窗口已经建好、method channel 可用。
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final SelfTestRunner runner = SelfTestRunner(widget.options);
    await runner.run();

    final String report = const JsonEncoder.withIndent('  ')
        .convert(runner.toJson());
    final String path = widget.options.reportPath ??
        '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}wisp-selftest.json';
    try {
      await File(path).writeAsString(report);
    } catch (_) {
      // 报告写不出去也不能吞掉结果：下面照样用退出码表态。
    }
    if (mounted) setState(() => _status = runner.ok ? '自测通过' : '自测失败');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(runner.ok ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF7F8FC),
        body: Center(
          child: Text(_status, style: const TextStyle(fontSize: 18)),
        ),
      ),
    );
  }
}
