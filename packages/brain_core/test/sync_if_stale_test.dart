import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 빠른 동기화: 폴더 시각만 보고 바뀐 게 있을 때만 전체 동기화 (설계서 5.8, 11/07 노트 1만 개 측정).
void main() {
  late Directory tmp;
  late Vault vault;
  late SearchIndex index;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('brain_stale_');
    vault = Vault(p.join(tmp.path, 'vault'))..ensure();
    index = SearchIndex.open(vault);
  });

  tearDown(() {
    index.close();
    tmp.deleteSync(recursive: true);
  });

  void write(String rel, String title) {
    final file = File(p.join(vault.root, rel))..parent.createSync(recursive: true);
    file.writeAsStringSync('---\nid: n_${title.hashCode.abs() % 9000 + 1000}\ntitle: "$title"\nsummary: "$title 요약"\n---\n\n$title 본문\n');
  }

  test('새 노트(새 폴더 포함)는 빠른 동기화에서도 바로 찾는다', () async {
    write('wiki/결제/웹훅 재시도.md', '웹훅 재시도');
    index.sync();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    write('wiki/배포/롤백 순서.md', '롤백 순서'); // 새 폴더
    final r = index.syncIfStale();
    expect(r.added, 1);
    expect(index.search('롤백 순서').map((d) => d.title), contains('롤백 순서'));
  });

  test('아무것도 안 바뀌면 전체 동기화를 건너뛴다', () async {
    write('wiki/결제/웹훅 재시도.md', '웹훅 재시도');
    index.sync();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final r = index.syncIfStale();
    expect(r.added + r.updated + r.removed, 0);
  });

  test('지운 노트는 빠른 동기화에서 빠진다', () async {
    write('wiki/결제/웹훅 재시도.md', '웹훅 재시도');
    write('wiki/결제/환불 규칙.md', '환불 규칙');
    index.sync();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    File(p.join(vault.root, 'wiki/결제/환불 규칙.md')).deleteSync();
    expect(index.syncIfStale().removed, 1);
  });

  test('제자리 수정은 fullEvery가 지나면 반영된다', () async {
    write('wiki/결제/웹훅 재시도.md', '웹훅 재시도');
    index.sync();
    final r = index.syncIfStale(fullEvery: Duration.zero);
    expect(r.added + r.updated + r.removed, 0); // 바뀐 게 없어도 전체를 봤다
    File(p.join(vault.root, 'wiki/결제/웹훅 재시도.md')).writeAsStringSync('---\nid: n_1\ntitle: "웹훅 재시도"\nsummary: "바뀜"\n---\n\n새 본문 지연시간\n');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(index.syncIfStale(fullEvery: Duration.zero).updated, 1);
  });
}
