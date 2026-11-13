import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late LessonStore lessons;
  late NoteStore notes;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('lessons_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    lessons = LessonStore(vault, index);
    notes = NoteStore(vault, index);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  test('실수 노트와 회귀 시험을 만들고 다시 읽는다', () {
    final (id, testId) = lessons.add(
      trigger: '결제 코드를 수정할 때',
      action: '테스트 키로 먼저 확인한다',
      reason: '실제 키로 바로 시험해 결제가 나간 적이 있음',
      diff: '- 실제 키로 바로 결제를 시험한다\n+ 테스트 키로 먼저 확인한다',
      status: LessonStatus.active,
      question: '결제 모듈에 새 카드사를 붙여 줘',
      bad: '실제 키로 바로 결제를 시험한다',
      expect: '테스트 키로 먼저 확인한다고 답한다',
    );
    expect(id, 'L-0001');
    expect(testId, 'T-0001');
    final lesson = lessons.read(id)!;
    expect(lesson.line, '결제 코드를 수정할 때 → 테스트 키로 먼저 확인한다');
    expect(lesson.diff, contains('+ 테스트 키'));
    expect(lesson.tests, ['T-0001']);
    expect(lessons.testsFor('카드사 결제 모듈').single.id, 'T-0001');
    // 실수 노트는 일반 노트 검색에 섞이지 않는다.
    expect(index.search('결제 코드'), isEmpty);
  });

  test('상황과 맞는 적용 중 규칙만 고른다 (승인 대기·관계없는 상황은 0개)', () {
    lessons.add(
      trigger: '결제 코드를 수정할 때',
      action: '테스트 키로 먼저 확인',
      reason: '사고',
      status: LessonStatus.active,
    );
    lessons.add(
      trigger: '배포 스크립트를 고칠 때',
      action: '스테이징에서 먼저',
      reason: '사고',
    );
    expect(lessons.match('결제 코드 좀 수정해 줘').single.id, 'L-0001');
    expect(lessons.match('배포 스크립트 고쳐 줘'), isEmpty); // pending
    expect(lessons.match('오늘 날씨 어때'), isEmpty);
    expect(lessons.match('결제 모듈 만들어'), isEmpty); // 3개 중 1개만
  });

  test('trigger 단어 머리로 맞춘다: 짧은 요청·영어 섞인 trigger', () {
    expect(LessonStore.wordHeads('결제 코드를 수정할 때'), ['결제', '코드', '수정']);
    expect(LessonStore.wordHeads('커밋하거나 push할 때'), ['커밋', 'push']);
    lessons.add(
      trigger: '커밋하거나 push할 때',
      action: '먼저 허락을 받는다',
      reason: '규칙',
      status: LessonStatus.active,
    );
    expect(lessons.match('커밋해 줘').single.action, '먼저 허락을 받는다');
    expect(lessons.match('Push 해'), hasLength(1));
  });

  test('근거 횟수를 남기고 온보딩 요약에 자주 받은 교정이 들어간다', () {
    final (id, _) = lessons.add(
      trigger: '커밋할 때',
      action: '매번 허락을 받는다',
      reason: '사용자 규칙',
      status: LessonStatus.active,
    );
    lessons.recordEvidence(id, kept: true);
    lessons.recordEvidence(id, kept: false);
    final lesson = lessons.read(id)!;
    expect((lesson.kept, lesson.recorrected), (1, 1));
    notes.add(title: '아무 노트', summary: '요약', body: '본문');
    expect(
      File(vault.profilePath).readAsStringSync(),
      contains('자주 받은 교정: 커밋할 때 → 매번 허락을 받는다'),
    );
  });

  test('AI 질문 근거: 노트 상위 5개 + 맞는 규칙, 적으면 검색어 다시 만들기', () {
    notes.add(title: '결제 웹훅 재시도', summary: '3번 재시도', body: '웹훅이 실패하면 1분 5분 30분 간격으로 다시 보낸다. 키는 sk-abcdefghijklmnopqrstuvwxyz0');
    lessons.add(trigger: '결제 코드를 수정할 때', action: '테스트 키로 먼저', reason: '사고', status: LessonStatus.active);
    final context = ChatContext.build(vault, index, '결제 웹훅이 실패하면 어떻게 해?');
    expect(context.notes.single.id, 'n_0001');
    expect(context.notes.single.snippet, isNot(contains('sk-abc')));
    expect(context.needsExpansion, isTrue);
    expect(ChatContext.build(vault, index, '결제 코드 수정해 줘').lessons, hasLength(1));
    appendChatLog(vault, question: '질문', answer: '답 [n_0001]', usedNoteIds: ['n_0001']);
    expect(Directory(p.join(vault.root, 'chats')).listSync(), hasLength(1));
  });

  test('검사 기준은 30항목까지', () {
    for (var i = 0; i < LessonStore.maxChecklist; i++) {
      lessons.addCheckItem('항목 $i');
    }
    expect(lessons.checklist().length, 30);
    expect(() => lessons.addCheckItem('하나 더'), throwsA(isA<NoteStoreException>()));
  });

  test('묶음 하나를 통째로 되돌린다: 고친 파일은 되살리고 새 파일은 휴지통으로', () {
    final (id, rel) = notes.add(
      title: '원래 노트',
      summary: '요약',
      body: '처음 본문',
      batch: 'b_first',
    );
    final found = notes.read(id)!;
    notes.write(id, '바뀐 본문', expectHash: found.$3, batch: 'b_ai');
    final (id2, rel2) = notes.add(
      title: 'AI가 만든 노트',
      summary: '요약',
      body: '본문',
      batch: 'b_ai',
    );
    expect(recentBatches(vault).map((b) => b.id), containsAll(['b_ai', 'b_first']));
    expect(undoBatch(vault, 'b_ai'), 2);
    expect(File(p.join(vault.root, rel)).readAsStringSync(), contains('처음 본문'));
    expect(File(p.join(vault.root, rel2)).existsSync(), isFalse);
    expect(
      File(p.join(vault.metaDir, 'trash', 'b_ai', rel2)).existsSync(),
      isTrue,
    );
    expect(() => undoBatch(vault, 'b_ai'), throwsArgumentError);
    index.sync();
    expect(index.byId(id2), isNull);
  });
}
