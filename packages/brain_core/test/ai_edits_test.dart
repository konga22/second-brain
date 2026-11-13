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

    test('초안을 AI가 고친 것은 카드가 아니다 (초안은 정리 대기에서 본다)', () {
      final (id, _) = store.add(title: '초안', summary: '요약', body: '처음\n', draft: true);
      markAiSession('s2');
      store.write(id, '고침\n', expectHash: store.read(id)!.$3, batch: newBatchId());
      markAiSession(null);
      expect(AiEditReview(vault, index).pending(), isEmpty);
    });
  });
}
