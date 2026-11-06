import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vault_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  test('노트를 저장하면 md 파일이 생기고 띄어쓰기와 상관없이 찾힌다', () {
    final (id, path) = store.add(
      title: '결제 웹훅 재시도 규칙',
      summary: '웹훅 실패 시 3번까지 간격을 늘려 재시도한다',
      body: '결제 오류가 나면 웹훅을 다시 보낸다.\n키는 sk-ant-api03-abcdefghijklmnopqrstuvwxyz 이다.',
      tags: ['결제'],
      draft: true,
    );
    expect(id, 'n_0001');
    expect(path, 'wiki/결제/결제 웹훅 재시도 규칙.md');
    final text = File(p.join(vault.root, path)).readAsStringSync();
    expect(text, contains('status: draft'));
    expect(text, contains('[가림]'));
    expect(text, isNot(contains('sk-ant')));
    expect(File(p.join(vault.root, 'AGENTS.md')).existsSync(), isTrue);

    expect(index.search('결제오류').map((d) => d.id), [id]);
    expect(index.search('웹훅').single.isDraft, isTrue);
    expect(index.search('배포'), isEmpty);
  });

  test('기대 해시가 다르면 쓰기를 거절하고 충돌 사본을 남긴다', () {
    final (id, _) = store.add(title: '메모', summary: '요약', body: '처음');
    final (_, _, hash) = store.read(id)!;
    final newHash = store.write(id, '두 번째', expectHash: hash);
    expect(store.read(id)!.$2.body.trim(), '두 번째');
    expect(
      () => store.write(id, '세 번째', expectHash: hash),
      throwsA(isA<NoteStoreException>()),
    );
    expect(
      Directory(p.join(vault.metaDir, 'conflicts')).listSync(),
      hasLength(1),
    );
    expect(store.read(id)!.$3, newHash);
  });

  test('요약이 60자를 넘으면 거절한다', () {
    expect(
      () => store.add(title: '제목', summary: '가' * 61, body: '본문'),
      throwsA(isA<NoteStoreException>()),
    );
  });

  test('색인을 지우고 다시 만들어도 같은 결과', () {
    store.add(
      title: '서버 배포',
      summary: '배포 전 환경변수 확인',
      body: '배포 전에 환경 변수를 확인한다',
    );
    expect(index.rebuild().added, 1);
    expect(index.search('환경변수').single.title, '서버 배포');
  });
}
