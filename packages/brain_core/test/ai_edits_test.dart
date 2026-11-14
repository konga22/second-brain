import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 정리 보드 "AI가 고친 노트" (설계서_프롬프트이후 4.3).
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('ai_edits_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index);
  });

  tearDown(() {
    markAiSession(null);
    index.close();
    temp.deleteSync(recursive: true);
  });

  group('4.3 AI가 고친 노트', () {
    test('AI 대화 표시가 붙은 고침만 카드가 되고, 되돌리면 본문이 고치기 전과 같다', () {
      final (id, _) = store.add(title: '로그인 토큰 만료', summary: '15분', body: '액세스 토큰 15분.\n');
      final (human, _) = store.add(title: '사람이 고친 노트', summary: '요약', body: '처음 본문\n');
      final original = store.read(id)!.$2.body;
      store.write(human, '사람이 고침\n', expectHash: store.read(human)!.$3, batch: newBatchId());

      markAiSession('3f2a9c1e-0000-4000-8000-000000000001');
      store.write(id, '액세스 토큰 30분.\n', expectHash: store.read(id)!.$3, batch: newBatchId());
      markAiSession(null);

      final review = AiEditReview(vault, index);
      final edits = review.pending();
      expect(edits.map((e) => e.noteId), [id], reason: '사람이 고친 노트는 카드가 되지 않는다');
      final edit = edits.single;
      expect(edit.sessions, {'3f2a9c1e-0000-4000-8000-000000000001'});
      expect(edit.canRevert, isTrue);
      final (before, after) = review.beforeAfter(edit);
      expect(before, contains('액세스 토큰 15분.'));
      expect(after, contains('액세스 토큰 30분.'));
      expect(
        lineDiff(before!, after).where((l) => l.kind != DiffKind.same).map((l) => '${l.kind.name}:${l.text}'),
        containsAll(['removed:액세스 토큰 15분.', 'added:액세스 토큰 30분.']),
      );

      review.revert(edit);
      expect(store.read(id)!.$2.body, original);
      expect(review.pending(), isEmpty, reason: '되돌린 고침은 다시 카드가 되지 않는다');
    });

    test('[확인함]을 누르면 카드가 사라지고 파일은 그대로다', () {
      final (id, _) = store.add(title: '배포 요일', summary: '화·목', body: '화·목 배포.\n');
      markAiSession('');
      store.write(id, '화·목·금 배포.\n', expectHash: store.read(id)!.$3, batch: newBatchId());
      markAiSession(null);
      final review = AiEditReview(vault, index);
      final edit = review.pending().single;
      expect(edit.sessions, isEmpty, reason: '대화 id를 모르면 AI 표시만 남는다');
      review.acknowledge(edit);
      expect(review.pending(), isEmpty);
      expect(store.read(id)!.$2.body.trim(), '화·목·금 배포.');
    });

    test('AI가 고친 뒤 사람이 또 고쳤으면 되돌리지 않는다 (사람 고침을 덮지 않게)', () {
      final (id, _) = store.add(title: '알림 시각', summary: '9시', body: '9시.\n');
      markAiSession('s1');
      store.write(id, '8시 30분.\n', expectHash: store.read(id)!.$3, batch: newBatchId());
      markAiSession(null);
      store.write(id, '8시.\n', expectHash: store.read(id)!.$3, batch: newBatchId());
      final review = AiEditReview(vault, index);
      final edit = review.pending().single;
      expect(edit.canRevert, isFalse);
      expect(() => review.revert(edit), throwsA(isA<NoteStoreException>()));
      expect(store.read(id)!.$2.body.trim(), '8시.');
    });

    test('변경 기록의 AI 표시는 내용에서 떼어 낸다 (할 일 키·회고·타임라인에 대화 id가 섞이지 않게)', () {
      markAiSession('3f2a9c1e-0000-4000-8000-000000000009');
      appendChangeLog(vault, 'todo-add', '보고서 쓰기');
      markAiSession('');
      appendChangeLog(vault, 'todo-add', '발표 연습');
      markAiSession(null);
      appendChangeLog(vault, 'todo-add', '사람이 넣은 일');
      final byText = {for (final e in readChangeHistory(vault)) e.detail: e};
      expect(byText.keys, containsAll(['보고서 쓰기', '발표 연습', '사람이 넣은 일']));
      expect(byText['보고서 쓰기']!.isAi, isTrue);
      expect(byText['보고서 쓰기']!.aiSession, '3f2a9c1e-0000-4000-8000-000000000009');
      expect(byText['발표 연습']!.isAi, isTrue);
      expect(byText['발표 연습']!.aiSession, isNull);
      expect(byText['사람이 넣은 일']!.isAi, isFalse);
      expect(stripAiMark('write n_0001 wiki/a.md · AI 대화 abc'), 'write n_0001 wiki/a.md');
      expect(stripAiMark('그대로'), '그대로');
    });

    test('초안을 AI가 고친 것은 카드가 아니다 (초안은 정리 대기에서 본다)', () {
      final (id, _) = store.add(title: '초안', summary: '요약', body: '처음\n', draft: true);
      markAiSession('s2');
      store.write(id, '고침\n', expectHash: store.read(id)!.$3, batch: newBatchId());
      markAiSession(null);
      expect(AiEditReview(vault, index).pending(), isEmpty);
    });
  });

  // 11/13 검토: [되돌리기]가 이 노트의 사람 기록만 보고 묶음 전체를 되살려, 같은 묶음에서 바뀐 다른 노트(제목을 바꿀 때
  // 고친 링크)의 뒤 고침이나 편집기로 고친 내용(기록이 없음)까지 지웠다.
  group('4.3 되돌리기는 남의 고침을 덮지 않는다 (11/13 검토)', () {
    String bodyOf(String id) => store.read(id)!.$2.body;

    /// A: AI가 본문을 고치고(묶음 1) 제목을 바꾼다(묶음 2, B의 링크도 고침).
    (String, String) aiRenameWithRelink() {
      final (a, _) = store.add(title: '배포 요일', summary: '화·목', body: '화·목 배포.\n');
      final (b, _) = store.add(title: '릴리스 절차', summary: '순서', body: '먼저 [[배포 요일]]을 본다.\n');
      markAiSession('s-rename');
      store.write(a, '화·목·금 배포.\n', expectHash: store.read(a)!.$3, batch: newBatchId());
      final (_, note, hash) = store.read(a)!;
      store.update(
        a,
        expectHash: hash,
        title: '배포 요일 규칙',
        summary: note.summary,
        body: note.body,
        tags: note.tags,
        aliases: note.aliases,
        batch: newBatchId(),
      );
      markAiSession(null);
      expect(bodyOf(b), contains('[[배포 요일 규칙]]'));
      return (a, b);
    }

    test('제목을 바꾸며 고친 다른 노트를 사람이 또 고쳤으면 되돌리지 않고, 아무 묶음도 되돌리지 않는다', () {
      final (a, b) = aiRenameWithRelink();
      store.write(b, '먼저 [[배포 요일 규칙]]을 본다.\n사람이 더한 줄.\n', expectHash: store.read(b)!.$3, batch: newBatchId());
      final review = AiEditReview(vault, index);
      final edit = review.pending().single;
      expect(edit.noteId, a);
      expect(
        () => review.revert(edit),
        throwsA(isA<NoteStoreException>().having((e) => e.message, 'message', allOf(contains(b), contains('릴리스 절차')))),
      );
      expect(bodyOf(b), contains('사람이 더한 줄.'), reason: '다른 노트의 사람 고침이 살아 있다');
      expect(store.read(a)!.$2.title, '배포 요일 규칙', reason: '반만 되돌리지 않는다 (묶음 1도 그대로)');
      expect(bodyOf(a).trim(), '화·목·금 배포.');
    });

    test('편집기로 고쳐 기록이 없어도 파일이 AI가 남긴 그대로가 아니면 되돌리지 않는다', () {
      final (a, _) = store.add(title: '알림 시각', summary: '9시', body: '9시.\n');
      markAiSession('s-editor');
      store.write(a, '8시 30분.\n', expectHash: store.read(a)!.$3, batch: newBatchId());
      markAiSession(null);
      final edit = AiEditReview(vault, index).pending().single;
      final file = File(p.join(vault.root, index.byId(a)!.path));
      file.writeAsStringSync(file.readAsStringSync().replaceFirst('8시 30분.', '8시 (편집기에서 고침).'));
      expect(() => AiEditReview(vault, index).revert(edit), throwsA(isA<NoteStoreException>()));
      expect(bodyOf(a), contains('편집기에서 고침'));
    });

    test('카드를 띄운 뒤 사람이 고쳤으면 옛 카드로 눌러도 되돌리지 않는다 (canRevert를 다시 본다)', () {
      final (a, _) = store.add(title: '백업 주기', summary: '매일', body: '매일 밤 백업.\n');
      markAiSession('s-stale');
      store.write(a, '매주 백업.\n', expectHash: store.read(a)!.$3, batch: newBatchId());
      markAiSession(null);
      final stale = AiEditReview(vault, index).pending().single;
      expect(stale.canRevert, isTrue);
      store.write(a, '매일 밤과 매주 백업.\n', expectHash: store.read(a)!.$3, batch: newBatchId());
      expect(() => AiEditReview(vault, index).revert(stale), throwsA(isA<NoteStoreException>()));
      expect(bodyOf(a).trim(), '매일 밤과 매주 백업.');
    });

    test('아무도 더 고치지 않았으면 제목·링크까지 함께 되돌린다', () {
      final (a, b) = aiRenameWithRelink();
      final review = AiEditReview(vault, index);
      review.revert(review.pending().single);
      expect(store.read(a)!.$2.title, '배포 요일');
      expect(bodyOf(a).trim(), '화·목 배포.');
      expect(bodyOf(b), contains('[[배포 요일]]'));
    });
  });
}
