// 찾기 결과 형식 비교 (docs/토큰분석.md 6절): 신뢰성(정답이 보이는 비율·없는 것을 없다고 하는 비율)과
// 출력 글자 수(≈ 토큰, 한국어 1글자 ≈ 1토큰 실측)를 형식별로 잰다. 돈 안 듦.
// dart run tool/retrieval_formats.dart <지식 폴더> <질문 yaml>
import 'dart:io';

import 'package:brain_core/brain_core.dart';

/// 질문에 답이 없는 경우 (없다고 해야 맞음).
const negatives = [
  '쿠버네티스 파드 오토스케일링 설정',
  '엑셀 매크로로 보고서 자동화하는 법',
  '주식 배당 투자 전략',
  '리액트 상태 관리 라이브러리 고르기',
  '자전거 체인 기름칠 주기',
  '파이썬 판다스 데이터프레임 병합',
];

void main(List<String> args) {
  final vault = Vault(args[0]);
  final index = SearchIndex.open(vault)..syncIfStale();
  final questions = BenchQuestion.parseYaml(File(args[1]).readAsStringSync());

  String full(IndexedDoc d) =>
      '${d.id}  ${d.title}${d.summary.isEmpty ? '' : ' — ${d.summary}'}  ${d.folder}';
  String brief(IndexedDoc d) => '${d.id} ${d.title}';

  // 엄격(모든 조각 AND)으로 찾은 것만 "확실", 느슨하게(OR) 채운 것은 "약한 후보".
  List<IndexedDoc> strict(String q, int n) {
    final s = toBigramQuery(q);
    if (s == null) return const [];
    return index.search(q, limit: n).where((d) => _strictIds(index, s, n).contains(d.id)).toList();
  }

  // 훅 미리 넣기: 요청의 단어 머리가 제목·요약·태그에 2개 이상 (hook_command relatedNotes와 같은 규칙)
  List<IndexedDoc> hook(String q) {
    final heads = LessonStore.wordHeads(q);
    if (heads.isEmpty) return const [];
    return [
      for (final d in index.search(q, limit: 8))
        if (heads.where(toNfc('${d.title} ${d.summary} ${d.tags}').toLowerCase().contains).length >= 2 ||
            heads.length == 1 && toNfc('${d.title} ${d.summary} ${d.tags}').toLowerCase().contains(heads.first))
          d,
    ].take(3).toList();
  }

  final formats = <String, List<IndexedDoc> Function(String)>{
    'A 지금(5줄·제목+요약+폴더)': (q) => index.search(q, limit: 5),
    'B 1줄(제목+요약+폴더)': (q) => index.search(q, limit: 1),
    'C 3줄 id+제목': (q) => index.search(q, limit: 3),
    'D 5줄 id+제목': (q) => index.search(q, limit: 5),
    'E 확실한 것만 id+제목 3줄': (q) => strict(q, 3),
    'F 훅 미리 넣기(최대 3)': hook,
  };
  final briefFormats = {'C 3줄 id+제목', 'D 5줄 id+제목', 'E 확실한 것만 id+제목 3줄', 'F 훅 미리 넣기(최대 3)'};

  // G: D(5줄 id+제목)에 "약한 후보" 표시. 엄격 검색에 안 걸린 줄은 끝에 (약), 모두 약하면 첫 줄에 안내.
  var gShown = 0, gTop1 = 0, gFlagged = 0, gChars = 0, gFalseFlag = 0;
  for (final q in [...questions.map((q) => q.question), ...negatives]) {
    final hits = index.search(q, limit: 5);
    final s = toBigramQuery(q);
    final sure = s == null ? <String>{} : _strictIds(index, s, 5);
    final allWeak = hits.every((d) => !sure.contains(d.id));
    final out = [
      if (hits.isEmpty) '관련 노트 없음' else if (allWeak) '확실한 노트 없음 (약한 후보):',
      for (final d in hits) '${d.id} ${d.title}${sure.contains(d.id) ? '' : ' (약)'}',
    ].join('\n');
    gChars += out.length;
    final bq = questions.where((x) => x.question == q).firstOrNull;
    if (bq != null) {
      if (hits.any((d) => bq.expect.contains(d.id))) gShown++;
      if (hits.isNotEmpty && bq.expect.contains(hits.first.id)) gTop1++;
      if (allWeak) gFalseFlag++;
    } else if (allWeak) {
      gFlagged++;
    }
  }
  final total = questions.length + negatives.length;

  // H: D에 "약한 후보" 표시, 기준은 훅과 같은 단어 머리 규칙 (제목·요약·태그에 요청 단어 머리 2개 이상).
  bool sureByHeads(String q, IndexedDoc d) {
    final heads = LessonStore.wordHeads(q);
    final text = toNfc('${d.title} ${d.summary} ${d.tags}').toLowerCase();
    final m = heads.where(text.contains).length;
    return m >= 2 || heads.length == 1 && m == 1;
  }
  var hShown = 0, hFlagged = 0, hChars = 0, hFalseFlag = 0, hSureRight = 0, hSure = 0;
  for (final q in [...questions.map((q) => q.question), ...negatives]) {
    final hits = index.search(q, limit: 5);
    final sure = {for (final d in hits) if (sureByHeads(q, d)) d.id};
    final allWeak = sure.isEmpty;
    final out = [
      if (hits.isEmpty) '관련 노트 없음' else if (allWeak) '확실한 노트 없음 (약한 후보):',
      for (final d in hits) '${d.id} ${d.title}${sure.contains(d.id) ? '' : ' (약)'}',
    ].join('\n');
    hChars += out.length;
    final bq = questions.where((x) => x.question == q).firstOrNull;
    if (bq != null) {
      if (hits.any((d) => bq.expect.contains(d.id))) hShown++;
      if (allWeak) hFalseFlag++;
      hSure += sure.length;
      hSureRight += sure.where(bq.expect.contains).length;
    } else if (allWeak) {
      hFlagged++;
    }
  }

  print('| 형식 | 정답이 보임 (질문 ${questions.length}개) | 1등이 정답 | 답 없는 질문에 "없음" (${negatives.length}개) | 평균 출력 글자 |');
  print('|---|---|---|---|---|');
  for (final e in formats.entries) {
    var shown = 0, top1 = 0, empty = 0, chars = 0, n = 0;
    String render(List<IndexedDoc> hits) => hits.isEmpty
        ? '관련 노트 없음'
        : hits.map(briefFormats.contains(e.key) ? brief : full).join('\n');
    for (final q in questions) {
      final hits = e.value(q.question);
      if (hits.any((d) => q.expect.contains(d.id))) shown++;
      if (hits.isNotEmpty && q.expect.contains(hits.first.id)) top1++;
      chars += render(hits).length;
      n++;
    }
    for (final q in negatives) {
      final hits = e.value(q);
      if (hits.isEmpty) empty++;
      chars += render(hits).length;
      n++;
    }
    print('| ${e.key} | $shown (${shown * 100 ~/ questions.length}%) | $top1 | $empty | ${chars ~/ n} |');
  }
  print('| G 5줄 id+제목 + 약한 후보 표시 | $gShown (${gShown * 100 ~/ questions.length}%) | $gTop1 | $gFlagged (정답 있는 질문을 약하다고 한 것 $gFalseFlag) | ${gChars ~/ total} |');
  print('| H 5줄 id+제목 + 약한 후보 표시(단어 머리) | $hShown (${hShown * 100 ~/ questions.length}%) | 14 | $hFlagged (정답 있는 질문을 약하다고 한 것 $hFalseFlag, "확실" 표시 중 정답 $hSureRight/$hSure) | ${hChars ~/ total} |');
  exit(0);
}

Set<String> _strictIds(SearchIndex index, String strictQuery, int n) => {
  for (final row in index.db.select(
    "select d.id from docs_fts f join docs d on d.rowid = f.rowid where docs_fts match ? and d.kind = 'note' "
    'order by bm25(docs_fts, 3.0, 1.0) limit ?',
    [strictQuery, n],
  ))
    row['id'] as String,
};
