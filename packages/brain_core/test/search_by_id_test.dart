import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 노트 번호로 찾기 (11/14 사용자 요청: "0081이나 0093하면 안 떠").
/// 번호는 본문 글이 아니라 2글자 조각 찾기로는 걸리지 않았다.
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;
  late List<String> ids;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('search_by_id_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index, zoned: false);
    ids = [
      for (var i = 0; i < 12; i++)
        store.add(title: '결제 웹훅 메모 $i', summary: '웹훅 재시도 $i', body: '결제 웹훅은 실패하면 다시 보낸다. 메모 $i.\n').$1,
    ];
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  test('번호를 여러 모양으로 써도 그 노트가 1위로 나온다', () {
    final target = ids[10]; // n_0011
    final digits = target.substring(2); // 0011
    for (final q in [target, 'n$digits', 'N_11', digits, '11', '$target 노트 보여 줘']) {
      final hits = index.search(q);
      expect(hits, isNotEmpty, reason: q);
      expect(hits.first.id, target, reason: q);
    }
  });

  test('바꾸기 전에는 번호만으로 안 걸렸다 — 이 시험이 실제로 새 동작을 본다', () {
    // 번호 없는 글자 찾기로는 n_0011이 1위가 아니다(모든 노트 본문이 같은 말).
    expect(index.search('결제 웹훅').first.id, isNot(ids[10]));
    expect(index.search(ids[10]).first.id, ids[10]);
  });

  test('번호 뒤에도 글자 찾기 결과가 이어지고, 같은 노트는 두 번 나오지 않는다', () {
    final hits = index.search('${ids[3]} 결제 웹훅', limit: 5);
    expect(hits.first.id, ids[3]);
    expect(hits.length, 5);
    expect(hits.map((d) => d.id).toSet().length, 5);
  });

  test('문장 속 숫자는 번호로 보지 않는다 (접두 없는 숫자는 검색어 전체가 숫자일 때만)', () {
    expect(SearchIndex.noteIdsInQuery('2026년 결제 11건'), isEmpty);
    expect(SearchIndex.noteIdsInQuery('버튼 21px 넘침'), isEmpty);
    expect(SearchIndex.noteIdsInQuery('vn_12 token_5'), isEmpty);
    expect(SearchIndex.noteIdsInQuery('n_0081, n_0093 합치기'), ['n_0081', 'n_0093']);
    expect(SearchIndex.noteIdsInQuery(' 0093 '), ['n_0093']);
  });

  test('없는 번호는 빈 결과, AI용 찾기에서는 확인 전 초안을 번호로도 내주지 않는다', () {
    expect(index.search('n_0999'), isEmpty);
    final draft = store.add(title: '확인 전 메모', summary: '초안', body: '아직 확인 전.\n', draft: true).$1;
    expect(index.search(draft).first.id, draft, reason: '사람이 보는 앱 검색은 초안도 보인다');
    expect(index.search(draft, includeDrafts: false).map((d) => d.id), isNot(contains(draft)));
  });
}
