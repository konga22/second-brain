import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures/similar_set.dart';

/// 주 1회 옛 결정 점검 (설계서_프롬프트이후 4.4 (나)).
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('decision_check_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  group('4.4 (나) 옛 결정 점검', () {
    final now = DateTime.now();
    final old = now.subtract(const Duration(days: 40));

    /// [created]로 만든 정리된 노트를 파일로 바로 쓴다 (NoteStore.add는 지금 시각을 쓴다).
    String put(FixtureNote n, DateTime created, int number) {
      final id = 'n_${number.toString().padLeft(4, '0')}';
      writeFileAtomic(
        p.join(vault.wikiDir, n.topic, '$id.md'),
        Note(id: id, title: n.title, summary: n.summary, body: n.body, created: created, updated: created).toMarkdown(),
      );
      return id;
    }

    test('최근 7일 노트를 같은 주제의 더 오래된 비슷한 노트와 짝짓는다 — 바꾼 결정은 잡고 관계만 있는 노트는 거의 안 잡는다', () {
      final olds = [for (final (i, n) in originals.indexed) put(n, old, i + 1)];
      for (final (i, n) in background.indexed) {
        put(n, old, 100 + i);
      }
      final news = [for (final (i, n) in changed.indexed) put(n, now, 200 + i)];
      final rel = [for (final (i, n) in related.indexed) put(n, now, 300 + i)];
      index.sync();
      final progress = <(int, int)>[];
      final pairs = DecisionCheck(vault, index).run(now: now, onProgress: (d, t) => progress.add((d, t)));
      final caught = [
        for (final (i, id) in news.indexed)
          if (pairs.any((x) => x.newId == id && x.oldId == olds[i])) id,
      ];
      final wrong = [
        for (final id in rel)
          if (pairs.any((x) => x.newId == id)) id,
      ];
      // ignore: avoid_print
      print('4.4 (나) 주간 점검: 바꾼 결정 ${caught.length}/10 짝지음, 같은 주제 다른 지식 ${wrong.length}/10 잘못 짝지음');
      expect(caught.length, greaterThanOrEqualTo(8));
      expect(wrong.length, lessThanOrEqualTo(1));
      expect(pairs.every((x) => x.oldId != x.newId), isTrue);
      expect(progress.last.$1, progress.last.$2, reason: '진행 표시가 끝까지 가야 한다');
      expect(progress.last.$2, 20, reason: '최근 7일에 만든 정리된 노트 20개를 본다 (40일 전 노트는 보지 않는다)');
    });

    test('[둘 다 맞음]은 다시 묻지 않고, [옛 노트 보관]은 옛 노트를 합쳐짐으로 바꿔 새 노트를 가리킨다', () {
      final a = put(originals[0], old, 1);
      final b = put(originals[1], old, 2);
      for (final (i, n) in background.indexed) {
        put(n, old, 100 + i);
      }
      final a2 = put(changed[0], now, 201);
      final b2 = put(changed[1], now, 202);
      index.sync();
      final check = DecisionCheck(vault, index);
      final pairs = check.run(now: now);
      final pa = pairs.firstWhere((x) => x.oldId == a && x.newId == a2);
      final pb = pairs.firstWhere((x) => x.oldId == b && x.newId == b2);

      check.keepBoth(pa);
      expect(check.pending().map((x) => x.oldId), isNot(contains(a)));
      expect(check.run(now: now).map((x) => x.oldId), isNot(contains(a)), reason: '둘 다 맞음을 누른 짝은 다시 묻지 않는다');

      check.archiveOld(store, pb);
      final (oldDoc, oldNote, _) = store.read(b)!;
      expect(oldDoc.isMerged, isTrue);
      expect(oldNote.extra['redirect'], b2);
      expect(check.pending().map((x) => x.oldId), isNot(contains(b)));
    });

    test('주 1회: 마지막 점검에서 7일이 지나야 다시 돈다', () {
      final check = DecisionCheck(vault, index);
      expect(check.isDue(now: now), isTrue, reason: '한 번도 안 돌았으면 돈다');
      check.run(now: now);
      expect(check.isDue(now: now.add(const Duration(days: 6))), isFalse);
      expect(check.isDue(now: now.add(const Duration(days: 7, minutes: 1))), isTrue);
    });
  });
}
