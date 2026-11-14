/// Android 平台能力：打开外链、把文件放进系统下载目录、拉起 APK 安装。
///
/// 与组播锁共用同一条 `wisp/android` 通道（见 MainActivity.kt）。桌面平台
/// 上所有方法都直接返回"不适用"，调用方可以先判断，也可以无条件调用。
library;

import 'dart:io';

import 'package:flutter/services.dart';

class WispAndroid {
  const WispAndroid._();

  static const MethodChannel _channel = MethodChannel('wisp/android');

  static bool get isAndroid => Platform.isAndroid;

  /// 用系统浏览器打开 http(s) 链接。
  ///
  /// 以前 Android 分支是空实现：更新弹层里所有下载链接点了只会得到一句
  /// 「当前平台暂不支持」，表现和"没反应"一样。
  static Future<bool> openUrl(String url) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'openUrl',
            <String, String>{'url': url},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 把已下好的文件发布到**系统下载目录**（Download/）。
  ///
  /// Android 10+ 的分区存储不允许直接往公共目录写文件，必须由原生层走
  /// MediaStore.Downloads；返回的 `content://` URI 同时就是安装用的句柄。
  /// 失败返回 null，调用方保留原来的本地路径。
  static Future<String?> saveToDownloads(String filePath) async {
    if (!isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>(
        'saveToDownloads',
        <String, String>{'path': filePath},
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 拉起系统安装界面。
  /// 返回 `'ok'` / `'permission_required'`（已代开设置页）/
  /// `'invalid_apk'`（包不完整或读不到，需重新下载）/ `'failed'`。
  /// 原生层会把 MediaStore 的 content:// 转成本应用 FileProvider 授权的
  /// 本地文件，避免安装器解析出空包（"packageInfo is null"）。
  static Future<String> installApk(String uriOrPath) async {
    if (!isAndroid) return 'failed';
    try {
      return await _channel.invokeMethod<String>(
            'installApk',
            <String, String>{'target': uriOrPath},
          ) ??
          'failed';
    } on MissingPluginException {
      return 'failed';
    } on PlatformException {
      return 'failed';
    }
  }

  /// 用系统默认应用打开一个本地文件（聊天附件点击）。
  /// 原生层用 FileProvider 生成 content:// URI 并授予读权限。
  static Future<bool> openFile(String filePath) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'openFile',
            <String, String>{'path': filePath},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
