import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/transfer.dart';

/// 文件挑选：文件、文件夹（递归）、纯文字（落成 .txt 再发，兼容协议）。
class Pickers {
  const Pickers._();

  static Future<List<TransferFile>> pickFiles() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      dialogTitle: '选择要发送的文件',
    );
    if (result == null) return <TransferFile>[];
    return result.files
        .where((PlatformFile f) => f.path != null)
        .map((PlatformFile f) => TransferFile(
              id: f.path!,
              name: f.name,
              size: f.size,
              path: f.path,
              mime: mimeFor(f.name),
            ))
        .toList();
  }

  static Future<List<TransferFile>> pickFolder() async {
    final String? dir = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择要发送的文件夹');
    if (dir == null) return <TransferFile>[];
    return expandFolder(dir);
  }

  /// 拖拽进来的路径：文件原样收，文件夹按「选文件夹」的规则递归展开。
  ///
  /// 原生层只给路径字符串，目录层级、相对路径、MIME 都在这里补齐，
  /// 这样拖拽和点按钮进待发清单的内容完全一致（名字里同样带根目录名）。
  static Future<List<TransferFile>> fromPaths(List<String> paths) async {
    final List<TransferFile> files = <TransferFile>[];
    for (final String path in paths) {
      final FileSystemEntityType type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.directory) {
        files.addAll(await expandFolder(path));
      } else if (type == FileSystemEntityType.file) {
        final File file = File(path);
        final int size = await file.length();
        final String name = path.split(Platform.pathSeparator).last;
        files.add(TransferFile(
          id: path,
          name: name,
          size: size,
          path: path,
          mime: mimeFor(name),
        ));
      }
    }
    return files;
  }

  /// 递归展开一个目录，文件名保留「根目录名/相对路径」，接收端才能还原结构。
  static Future<List<TransferFile>> expandFolder(String dir) async {
    // 末尾分隔符会让下面的 substring 多切一个字符，先统一去掉。
    String rootPath = dir;
    while (rootPath.length > 3 && (rootPath.endsWith(Platform.pathSeparator) || rootPath.endsWith('/'))) {
      rootPath = rootPath.substring(0, rootPath.length - 1);
    }
    final List<TransferFile> files = <TransferFile>[];
    final Directory root = Directory(rootPath);
    final String rootName = root.uri.pathSegments.lastWhere((String s) => s.isNotEmpty, orElse: () => '文件夹');
    await for (final FileSystemEntity entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final String relative =
          entity.path.substring(rootPath.length + 1).split(Platform.pathSeparator).join('/');
      final int size = await entity.length();
      files.add(TransferFile(
        id: entity.path,
        name: '$rootName/$relative',
        size: size,
        path: entity.path,
        mime: mimeFor(relative),
      ));
    }
    return files;
  }

  /// 文字消息按协议惯例落成 .txt：接收端就是普通文件，不引入私有格式。
  static Future<TransferFile?> textToFile(String text) async {
    if (text.trim().isEmpty) return null;
    final Directory dir = await getTemporaryDirectory();
    final File file = File('${dir.path}${Platform.pathSeparator}Wisp-文字-${DateTime.now().millisecondsSinceEpoch}.txt');
    await file.writeAsString(text, encoding: const SystemEncoding());
    final int size = await file.length();
    return TransferFile(
      id: file.path,
      name: file.uri.pathSegments.last,
      size: size,
      path: file.path,
      mime: 'text/plain',
    );
  }

  /// 按扩展名猜 MIME。历史记录里"再次发送"也要用同一套判断，所以公开。
  static String mimeFor(String name) {
    final String ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
      case 'md':
        return 'text/plain';
      case 'zip':
        return 'application/zip';
      case 'apk':
        return 'application/vnd.android.package-archive';
      default:
        return 'application/octet-stream';
    }
  }
}
