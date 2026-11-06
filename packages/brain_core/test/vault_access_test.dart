import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:test/test.dart';

void main() {
  test('지식 폴더에 쓰고 읽고 변경을 감시하고, 시험 파일은 남기지 않는다', () async {
    final dir = await Directory.systemTemp.createTemp('vault_');
    addTearDown(() => dir.delete(recursive: true));

    final access = await checkVaultAccess(dir.path);

    expect(access.error, isNull);
    expect(access.isReady, isTrue);
    expect(dir.listSync(), isEmpty);
  });
}
