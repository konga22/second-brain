import 'dart:io';
import 'dart:math';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('edit_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  test('제목을 바꾸면 파일 이름과 다른 노트의 [[링크]]가 함께 바뀐다', () {
    final (a, _) = store.add(title: '토스 키', summary: '키 위치', body: '본문', tags: ['결제']);
    final (b, bPath) = store.add(
      title: '결제 웹훅',
      summary: '재시도',
      body: '[[토스 키]]와 [[토스 키#섹션|여기]]를 본다',
      tags: ['결제'],
    );
    final hash = store.read(a)!.$3;
    store.update(a, expectHash: hash, title: '토스 테스트 키', summary: '키 위치', body: '본문 2', tags: ['결제']);
    expect(File(p.join(vault.wikiDir, '결제', '토스 키.md')).existsSync(), isFalse);
    expect(File(p.join(vault.wikiDir, '결제', '토스 테스트 키.md')).existsSync(), isTrue);
    final linking = File(p.join(vault.root, bPath)).readAsStringSync();
    expect(linking, contains('[[토스 테스트 키]]와 [[토스 테스트 키#섹션|여기]]'));
    expect(index.deadLinks(), isEmpty);
    expect(index.links().where((l) => !l.isSuggested && l.fromId == b).single.toId, a);
  });

  test('해시가 다르면 편집을 거절하고 충돌 사본을 남긴다', () {
    final (a, _) = store.add(title: '가', summary: '가', body: '본문');
    expect(
      () => store.update(a, expectHash: 'deadbeef0000', title: '가', summary: '가', body: '새 본문'),
      throwsA(isA<NoteStoreException>()),
    );
    expect(Directory(p.join(vault.metaDir, 'conflicts')).listSync(), hasLength(1));
  });

  test('지운 노트는 휴지통으로 가고 undo로 되살아난다', () {
    final (a, path) = store.add(title: '지울 노트', summary: '요약', body: '본문');
    final batch = store.delete(a);
    expect(File(p.join(vault.root, path)).existsSync(), isFalse);
    expect(index.byId(a), isNull);
    undoBatch(vault, batch);
    index.sync();
    expect(index.byId(a)?.title, '지울 노트');
  });

  test('할 일: 추가·완료·삭제, 노트의 체크 상자도 모은다', () {
    final todos = TodoStore(vault, index);
    todos.add('보고서 쓰기');
    todos.add('발표 연습');
    todos.toggle(todos.list().first);
    expect(todos.list().map((t) => (t.text, t.isDone)), [('보고서 쓰기', true), ('발표 연습', false)]);
    todos.remove(todos.list().last);
    expect(todos.list(), hasLength(1));
    store.add(title: '회의', summary: '요약', body: '- [ ] 자료 보내기\n- [x] 끝난 일');
    expect(todos.fromNotes().single.text, '자료 보내기');
  });

  test('변경 기록을 최신 순으로 읽고 대상 id를 뽑는다', () {
    store.add(title: '가', summary: '가', body: '본문', batch: 'b_1');
    final events = readChangeHistory(vault);
    expect(events.first.action, 'add');
    expect(events.first.batch, 'b_1');
    expect(events.first.targetId, 'n_0001');
  });

  test('텍스트 원본 가져오기: raw/에 저장, 비밀값 가림, 원본으로 색인', () {
    final result = importText(
      vault,
      name: '주간회의.txt',
      text: '배포는 화요일만.\nOPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx',
      kind: ImportKind.meeting,
    );
    expect(result.relPath, startsWith('raw/meetings/'));
    expect(result.maskedCount, greaterThan(0));
    final text = File(p.join(vault.root, result.relPath)).readAsStringSync();
    expect(text, isNot(contains('sk-abc')));
    index.sync();
    expect(index.search('배포', includeRaw: true).single.kind, 'raw');
    expect(index.search('배포'), isEmpty); // 기본 검색에서는 원본 제외
  });

  test('force 배치: 연결된 노드는 가깝고, 같은 입력이면 같은 결과', () {
    final nodes = [
      for (var i = 0; i < 30; i++) GraphNode('n$i', i < 15 ? 'a' : 'b'),
    ];
    final edges = [const GraphEdge('n0', 'n1'), const GraphEdge('n15', 'n16')];
    final first = forceLayout(nodes, edges);
    final second = forceLayout(nodes, edges);
    expect(first['n7'], second['n7']);
    double dist(String a, String b) => first[a]!.distanceTo(first[b]!);
    expect(dist('n0', 'n1'), lessThan(dist('n0', 'n20')));
  });

  test('force 배치 성능: 노드 1만 개', () {
    final random = Random(1);
    final nodes = [for (var i = 0; i < 10000; i++) GraphNode('n$i', 'g${i % 20}')];
    final edges = [
      for (var i = 0; i < 15000; i++)
        GraphEdge('n${random.nextInt(10000)}', 'n${random.nextInt(10000)}'),
    ];
    final watch = Stopwatch()..start();
    final positions = forceLayout(nodes, edges, iterations: 300);
    final full = watch.elapsedMilliseconds;
    watch.reset();
    final cached = forceLayout(nodes, edges, initial: positions);
    final cachedMs = watch.elapsedMilliseconds;
    watch.reset();
    final withNew = forceLayout(
      [...nodes, const GraphNode('new', 'g1')],
      edges,
      initial: positions,
    );
    print('1만 노드 배치: 처음 ${full}ms, 저장된 위치 그대로 ${cachedMs}ms, 새 노드 1개 ${watch.elapsedMilliseconds}ms');
    expect(cached['n5'], positions['n5']);
    expect(withNew, hasLength(10001));
    expect(positions, hasLength(10000));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
