import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures/similar_set.dart';

/// 정리 대기 카드의 [합치기] (설계서_프롬프트이후 4.2).
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('merge_draft_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  group('4.2 [합치기]', () {
    test('초안마다 비슷한 정리된 노트를 최대 2개 붙인다 (중복 초안에는 원래 노트, 관계없는 초안에는 없음)', () {
      final ids = [
        for (final n in originals) store.add(title: n.title, summary: n.summary, body: n.body, topic: n.topic).$1,
      ];
      for (final n in background) {
        store.add(title: n.title, summary: n.summary, body: n.body, topic: n.topic);
      }
      final dup = store.add(title: duplicates[2].title, summary: duplicates[2].summary, body: duplicates[2].body, draft: true).$1;
      final other = store.add(title: unrelated[0].title, summary: unrelated[0].summary, body: unrelated[0].body, draft: true).$1;
      final similar = store.similarForDrafts();
      expect(similar[dup]!.first.doc.id, ids[2]);
      expect(similar[dup]!.length, lessThanOrEqualTo(2));
      expect(similar.containsKey(other), isFalse);
    });

    test('초안 본문을 정리된 노트 끝에 붙이고, 초안은 합쳐짐으로 남아 그 노트를 가리킨다. 한 묶음으로 되돌린다', () {
      final (target, _) = store.add(title: '결제 웹훅 재시도 규칙', summary: '3번', body: '3번까지 다시 보낸다.\n');
      final (draft, _) = store.add(title: '웹훅 간격', summary: '1·5·30분', body: '간격은 1분, 5분, 30분.\n', draft: true);
      final before = store.read(target)!.$2.body;
      final batch = store.mergeDraftInto(draft, target);

      final merged = store.read(target)!.$2;
      expect(merged.body, startsWith(before.trimRight()));
      expect(merged.body, contains('간격은 1분, 5분, 30분.'));
      expect(merged.body, contains('합친 초안: 웹훅 간격'));
      final (draftDoc, draftNote, _) = store.read(draft)!;
      expect(draftDoc.isMerged, isTrue, reason: '초안은 지우지 않고 합쳐짐으로 남긴다');
      expect(draftNote.extra['redirect'], target);

      undoBatch(vault, batch);
      index.sync();
      expect(store.read(target)!.$2.body, before);
      expect(store.read(draft)!.$1.isDraft, isTrue);
    });

    // 11/13 검토: 기존 노트에 붙인 뒤 초안을 "합쳐짐"으로 바꾸다 실패하면 붙인 것만 남아, 다시 누르면 두 번 붙었다.
    test('초안 표시가 실패하면 붙인 것도 되돌리고, 다시 합쳐도 한 번만 붙는다 (11/13 검토)', () {
      final (target, _) = store.add(title: '결제 웹훅 재시도 규칙', summary: '3번', body: '3번까지 다시 보낸다.\n', topic: '결제');
      final (draft, draftPath) = store.add(
        title: '웹훅 간격',
        summary: '1·5·30분',
        body: '간격은 1분, 5분, 30분.\n',
        draft: true,
        topic: '초안칸',
      );
      final before = store.read(target)!.$2.body;
      // 초안 폴더를 읽기 전용으로: 대상 노트는 고쳐지고 초안 쓰기(markMerged)만 실패한다
      final draftDir = p.dirname(p.join(vault.root, draftPath));
      Process.runSync('chmod', ['555', draftDir]);
      try {
        expect(() => store.mergeDraftInto(draft, target), throwsA(anything));
      } finally {
        Process.runSync('chmod', ['755', draftDir]);
      }
      expect(store.read(target)!.$2.body, before, reason: '반만 합쳐진 채 남지 않는다');
      expect(store.read(draft)!.$1.isDraft, isTrue);

      store.mergeDraftInto(draft, target);
      final merged = store.read(target)!.$2.body;
      expect('합친 초안: 웹훅 간격'.allMatches(merged).length, 1, reason: '다시 눌러도 한 번만 붙는다');
      expect(store.read(draft)!.$1.isMerged, isTrue);
    });

    test('붙인 뒤 끊겨 초안만 남았어도 다시 합치면 또 붙이지 않는다 (11/13 검토)', () {
      final (target, _) = store.add(title: '배포 요일 규칙', summary: '화·목', body: '배포는 화요일과 목요일.\n');
      final (draft, _) = store.add(title: '금요일 배포', summary: '금지', body: '금요일에는 배포하지 않는다.\n', draft: true);
      // 예전 판에서 붙이기만 하고 끊긴 상태를 만든다
      final (_, note, hash) = store.read(target)!;
      store.write(
        target,
        '${note.body.trimRight()}\n\n## 합친 초안: 금요일 배포 (2026-11-13, $draft)\n\n금요일에는 배포하지 않는다.\n',
        expectHash: hash,
      );
      store.mergeDraftInto(draft, target);
      expect('합친 초안: 금요일 배포'.allMatches(store.read(target)!.$2.body).length, 1);
      expect(store.read(draft)!.$1.isMerged, isTrue);
    });

    test('초안이 아니거나 대상이 정리된 노트가 아니면 합치지 않는다', () {
      final (a, _) = store.add(title: '가', summary: '가', body: '가 본문\n');
      final (b, _) = store.add(title: '나', summary: '나', body: '나 본문\n');
      final (d, _) = store.add(title: '다', summary: '다', body: '다 본문\n', draft: true);
      final (d2, _) = store.add(title: '라', summary: '라', body: '라 본문\n', draft: true);
      expect(() => store.mergeDraftInto(a, b), throwsA(isA<NoteStoreException>()));
      expect(() => store.mergeDraftInto(d, d2), throwsA(isA<NoteStoreException>()));
    });

    test('AI 찾기(초안 뺌)는 합쳐진 노트도 뺀다 — 사람용 찾기에는 남는다', () {
      final (keep, _) = store.add(title: '배포 요일 규칙', summary: '화·목', body: '배포는 화요일과 목요일.\n');
      final (old, _) = store.add(title: '배포 요일 옛 규칙', summary: '월·수', body: '배포는 월요일과 수요일.\n');
      store.markMerged(old, into: keep);
      expect(index.search('배포 요일', includeDrafts: false).map((d) => d.id), isNot(contains(old)));
      expect(index.search('배포 요일').map((d) => d.id), contains(old));
    });
  });
}
