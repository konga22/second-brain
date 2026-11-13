import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures/similar_set.dart';

/// 비슷한 정리된 노트 (설계서_프롬프트이후 4.2 M5, 4.4 저장 때 안내 문턱).
/// 점수는 추천 연결과 같다: 새 노트의 핵심 단어 5개 중 상대 노트에 나오는 수.
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('similar_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  String add(FixtureNote n, {bool draft = false}) =>
      store.add(title: n.title, summary: n.summary, body: n.body, topic: n.topic, draft: draft).$1;

  Note asNote(FixtureNote n) => Note(id: 'new', title: n.title, summary: n.summary, body: n.body);

  /// 정리된 노트(원래 10개 + 배경 20개)를 넣고 원래 노트 id를 돌려준다.
  List<String> seed() {
    final ids = [for (final n in originals) add(n)];
    for (final n in background) {
      add(n);
    }
    return ids;
  }

  test('정리된 노트만 찾는다: 초안·합쳐짐·자기 자신은 빼고, 점수 높은 순', () {
    // 노트 3개짜리 폴더는 드문 정도(idf)가 뜻이 없어, 실제 폴더처럼 배경 노트를 함께 넣는다.
    final original = seed().first;
    final draft = add(duplicates[0], draft: true);
    final merged = add(changed[0]);
    store.markMerged(merged, into: original);
    final found = index.similarNotes(store.read(draft)!.$2, excludeId: draft, minShared: 1);
    expect(found.first.doc.id, original);
    expect(found.map((s) => s.doc.id), isNot(contains(merged)), reason: '합쳐진 노트는 빼야 한다');
    expect(found.map((s) => s.doc.id), isNot(contains(draft)));
    expect(found.first.shared, greaterThanOrEqualTo(SearchIndex.similarShowMin));
    expect(found.first.terms, 5);
    // 초안은 다른 노트의 비슷한 노트로 나오지 않는다
    final fromOriginal = index.similarNotes(store.read(original)!.$2, excludeId: original, minShared: 1, limit: 50);
    expect(fromOriginal.map((s) => s.doc.id), isNot(contains(draft)));
    expect(fromOriginal.map((s) => s.doc.id), isNot(contains(original)));
  });

  test('M5: 중복 초안 10개 중 표시 / 중복 아닌 초안 20개 중 오표시 — 문턱별로 재고 표시 문턱을 지킨다', () {
    final ids = seed();
    final dup = [for (final n in duplicates) add(n, draft: true)];
    final rel = [for (final n in related) add(n, draft: true)];
    final unrel = [for (final n in unrelated) add(n, draft: true)];
    List<SimilarNote> top(String id) =>
        index.similarNotes(store.read(id)!.$2, excludeId: id, minShared: 1, limit: 2);
    final rows = <String>[];
    final shownAt = <int, (int, int, int)>{};
    for (var t = 1; t <= 5; t++) {
      var hit = 0, wrongRelated = 0, wrongUnrelated = 0;
      for (final (i, id) in dup.indexed) {
        if (top(id).any((s) => s.shared >= t && s.doc.id == ids[i])) hit++;
      }
      for (final id in rel) {
        if (top(id).any((s) => s.shared >= t)) wrongRelated++;
      }
      for (final id in unrel) {
        if (top(id).any((s) => s.shared >= t)) wrongUnrelated++;
      }
      shownAt[t] = (hit, wrongRelated, wrongUnrelated);
      rows.add('  문턱 $t: 중복 $hit/10 표시, 같은 주제 다른 지식 $wrongRelated/10 오표시, 관계없는 지식 $wrongUnrelated/10 오표시');
    }
    // ignore: avoid_print
    print('M5 (핵심 단어 5개 중 겹친 수):\n${rows.join('\n')}');
    final (hit, wrongRelated, wrongUnrelated) = shownAt[SearchIndex.similarShowMin]!;
    expect(shownAt[1]!.$3, greaterThan(wrongUnrelated), reason: '문턱이 아무것도 거르지 않으면 이 시험은 문턱을 재지 않는다');
    expect(hit, greaterThanOrEqualTo(8), reason: '중복 초안 대부분에 원래 노트가 보여야 한다');
    expect(wrongUnrelated, lessThanOrEqualTo(1));
    expect(wrongRelated, lessThanOrEqualTo(3));
  });

  test('4.4 문턱: 결정을 바꾼 노트 10개 중 멈춤 / 같은 주제 다른 지식 10개 중 잘못 멈춤', () {
    final ids = seed();
    final rows = <String>[];
    final at = <int, (int, int, int)>{};
    for (var t = 1; t <= 5; t++) {
      var stopChanged = 0, stopDup = 0, wrongStop = 0;
      for (final (i, n) in changed.indexed) {
        final best = index.similarNotes(asNote(n), minShared: t, limit: 1);
        if (best.isNotEmpty && best.first.doc.id == ids[i]) stopChanged++;
      }
      for (final (i, n) in duplicates.indexed) {
        final best = index.similarNotes(asNote(n), minShared: t, limit: 1);
        if (best.isNotEmpty && best.first.doc.id == ids[i]) stopDup++;
      }
      for (final n in related) {
        if (index.similarNotes(asNote(n), minShared: t, limit: 1).isNotEmpty) wrongStop++;
      }
      at[t] = (stopChanged, stopDup, wrongStop);
      rows.add('  문턱 $t: 바꾼 결정 $stopChanged/10 멈춤, 같은 지식 다시 저장 $stopDup/10 멈춤, 같은 주제 다른 지식 $wrongStop/10 잘못 멈춤');
    }
    // ignore: avoid_print
    print('4.4 저장 때 멈춤 (핵심 단어 5개 중 겹친 수):\n${rows.join('\n')}');
    final (stopChanged, _, wrongStop) = at[SearchIndex.similarStrongMin]!;
    expect(at[1]!.$3, greaterThan(wrongStop), reason: '문턱이 아무것도 거르지 않으면 이 시험은 문턱을 재지 않는다');
    expect(stopChanged, greaterThanOrEqualTo(8), reason: '바꾼 결정 대부분에서 옛 노트를 보여 주고 멈춰야 한다');
    expect(wrongStop, lessThanOrEqualTo(1), reason: '관계만 있는 노트에서 멈추면 대화가 쓸데없이 길어진다');
  });
}
