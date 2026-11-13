import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 앱 [연동]이 `brain`을 덮어쓸 때 (K-22 나머지, 11/12): 임시 파일 → 이름 바꾸기.
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('atomic_write_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('덮어쓰는 동안 이미 열린 쪽은 옛 내용을 끝까지 읽고, 임시 파일은 남지 않는다', () {
    final path = p.join(temp.path, 'bin', 'brain');
    final old = List<int>.generate(4 * 1024 * 1024, (i) => i % 251);
    writeBytesAtomic(path, old, executable: true);
    expect(File(path).statSync().mode & 0x40, isNot(0), reason: '실행 권한');

    // 실행 중인 brain처럼 옛 파일을 연 채로 새 판을 넣는다
    final reader = File(path).openSync();
    final first = reader.readSync(1024);
    final fresh = List<int>.generate(3 * 1024 * 1024, (i) => (i * 7) % 253);
    writeBytesAtomic(path, fresh, executable: true);
    final rest = reader.readSync(old.length);
    reader.closeSync();
    expect([...first, ...rest], old, reason: '열려 있던 쪽은 옛 내용 그대로 (제자리 덮어쓰기면 섞인다)');

    expect(File(path).readAsBytesSync(), fresh);
    expect(File(path).statSync().mode & 0x40, isNot(0));
    expect(Directory(p.dirname(path)).listSync().map((e) => p.basename(e.path)), ['brain']);
  });

  test('제자리 덮어쓰기는 열린 쪽에 새 내용이 섞인다 — 고치기 전 방식과 비교', () {
    final path = p.join(temp.path, 'brain');
    final old = List<int>.generate(4 * 1024 * 1024, (i) => i % 251);
    File(path).writeAsBytesSync(old);
    final reader = File(path).openSync();
    final first = reader.readSync(1024);
    File(path).writeAsBytesSync(List<int>.generate(3 * 1024 * 1024, (i) => (i * 7) % 253));
    final rest = reader.readSync(old.length);
    reader.closeSync();
    expect([...first, ...rest], isNot(old));
  });
}
