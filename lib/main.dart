import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'selftest/selftest.dart';
import 'state/app_state.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );

  // 受控自测入口（见 lib/selftest/selftest.dart）：带 --wisp-* 参数时
  // 不启动正常界面，跑完把结果写进 JSON 报告并用退出码表态。
  final WispCliOptions? cli = WispCliOptions.parse(args);
  if (cli != null) {
    runApp(SelfTestApp(options: cli));
    return;
  }

  final AppState state = AppState();
  // 先渲染启动页，网络和存储在后台就绪，避免白屏等待。
  unawaited(state.init());

  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const WispApp(),
    ),
  );
}
