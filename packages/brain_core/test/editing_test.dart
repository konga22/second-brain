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

  test('폴더(뇌): 만들기·옮기기·범위 검색·추천 정리', () {
    store.createTopic('대학교');
    expect(index.topics(), contains('대학교'));
    final (a, _) = store.add(title: '자료구조 스택', summary: '후입선출', body: '스택은 후입선출 자료구조다', tags: ['메모']);
    store.add(title: '자료구조 큐', summary: '선입선출', body: '큐는 선입선출 자료구조다. [[자료구조 스택]]과 비교', tags: ['대학교']);
    store.add(title: '자료구조 힙', summary: '우선순위', body: '힙은 우선순위 큐 자료구조다. [[자료구조 스택]]', tags: ['대학교']);
    expect(store.suggestMoves().map((m) => (m.$1, m.$3)), contains((a, '대학교')));
    store.move(a, '대학교');
    expect(index.byId(a)!.topic, '대학교');
    expect(index.deadLinks(), isEmpty);
    store.add(title: '회사 스택 규칙', summary: '회사', body: '회사에서 쓰는 기술 스택', tags: ['회사']);
    expect(index.search('스택', topic: '대학교').every((d) => d.topic == '대학교'), isTrue);
    final scoped = ChatContext.build(vault, index, '스택', topic: '회사');
    expect(scoped.notes.first.title, '회사 스택 규칙'); // 그 뇌에서 먼저
    expect(scoped.notes.length, greaterThan(1)); // 모자라면 전체에서 채움
  });

  test('할 일 추천: 추천 칸에 넣고, 받으면 확정 목록으로', () {
    final todos = TodoStore(vault, index);
    todos.add('보고서 쓰기');
    expect(todos.suggest('발표 자료 만들기', source: 'n_0001'), isTrue);
    expect(todos.suggest('발표 자료 만들기'), isFalse); // 중복
    expect(todos.list().map((t) => t.text), ['보고서 쓰기']);
    final s = todos.suggestions().single;
    expect((s.text, s.noteId), ('발표 자료 만들기', 'n_0001'));
    todos.accept(s);
    expect(todos.suggestions(), isEmpty);
    expect(todos.list().map((t) => t.text), ['보고서 쓰기', '발표 자료 만들기']);
    todos.add('세 번째');
    expect(todos.list().last.text, '세 번째');
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
    // 새 노트 1개(기존 n5와 연결)를 더한다: 기존 노드는 그대로, 새 노드만 n5 근처에.
    final withNew = forceLayout(
      [...nodes, const GraphNode('new', 'g5')], // n5와 같은 주제
      [...edges, const GraphEdge('new', 'n5')],
      initial: positions,
    );
    final newMs = watch.elapsedMilliseconds;
    watch.reset();
    // 새 노트 10개를 한꺼번에 (자동 저장·가져오기)
    final withTen = forceLayout(
      [...nodes, for (var i = 0; i < 10; i++) GraphNode('new$i', 'g${i % 3}')],
      [...edges, for (var i = 0; i < 10; i++) GraphEdge('new$i', 'n${i * 7}')],
      initial: positions,
    );
    final tenMs = watch.elapsedMilliseconds;
    print('1만 노드 배치: 처음 ${full}ms, 저장된 위치 그대로 ${cachedMs}ms, 새 노드 1개 ${newMs}ms, 새 노드 10개 ${tenMs}ms');
    expect(cached['n5'], positions['n5']);
    expect(withNew, hasLength(10001));
    expect(withTen, hasLength(10010));
    // 기존 노드는 움직이지 않는다 (화면이 흔들리지 않게)
    expect(withNew['n123'], positions['n123']);
    expect(withTen['n9999'], positions['n9999']);
    // 새 노드는 연결된 노드 근처에 (그래프 폭에 비해 가깝게)
    final d = withNew['new']!.distanceTo(positions['n5']!);
    expect(d, lessThan(400), reason: '연결된 n5와 $d 떨어짐');
    expect(newMs, lessThan(500), reason: '새 노드 1개를 더하는 데 전체 배치(2.4초)를 다시 하지 않는다');
    expect(positions, hasLength(10000));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
