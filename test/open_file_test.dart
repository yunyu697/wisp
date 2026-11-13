import 'package:flutter_test/flutter_test.dart';

import 'package:wisp/core/utils/open_file.dart';
import 'package:wisp/services/update_installer.dart';

/// 附件打开 / 更新结果展示的纯逻辑护栏。
void main() {
  test('文件不在本机时给出明确原因，而不是静默失败', () async {
    final OpenFileResult result =
        await openLocalFile('/no/such/path/report.pdf');
    expect(result.opened, isFalse);
    expect(result.message, isNotNull);
    expect(result.message, isNotEmpty);
  });

  test('空路径给出明确原因', () async {
    final OpenFileResult result = await openLocalFile('');
    expect(result.opened, isFalse);
    expect(result.message, contains('路径'));
  });

  test('MediaStore 的 content URI 展示成人话', () {
    expect(
      WispUpdateInstaller.describeArtifact(
          'content://media/external/downloads/42'),
      contains('系统下载目录'),
    );
    expect(
      WispUpdateInstaller.describeArtifact('/home/me/Downloads/wisp.apk'),
      '/home/me/Downloads/wisp.apk',
    );
  });
}
