// "확실히 맞음" 판정 규칙 비교: 답 있는 질문의 정답을 남기는 비율 vs 답 없는 질문을 "없음"으로 하는 비율.
// dart run tool/strong_rules.dart <지식 폴더> <질문 yaml>
import 'dart:io';

import 'package:brain_core/brain_core.dart';

const negatives = [
  '쿠버네티스 파드 오토스케일링 설정', '엑셀 매크로로 보고서 자동화하는 법', '주식 배당 투자 전략',
  '리액트 상태 관리 라이브러리 고르기', '자전거 체인 기름칠 주기', '파이썬 판다스 데이터프레임 병합',
];

void main(List<String> args) {
  final vault = Vault(args[0]);
  final index = SearchIndex.open(vault)..syncIfStale();
  final qs = BenchQuestion.parseYaml(File(args[1]).readAsStringSync());
  final bodies = <String, String>{};
  String body(IndexedDoc d) => bodies[d.id] ??= toNfc(noteBody(vault, d)).toLowerCase();
  int matched(String q, String text) => LessonStore.wordHeads(q).where(text.contains).length;
  int heads(String q) => LessonStore.wordHeads(q).length;
  final rules = <String, bool Function(String, IndexedDoc, int)>{
    '제목·요약·태그 2개 (지금)': (q, d, rank) => isStrongMatch(q, d),
    '본문 포함 2개': (q, d, rank) {
      final m = matched(q, toNfc('${d.title} ${d.summary} ${d.tags}').toLowerCase() + body(d));
      return m >= 2 || heads(q) == 1 && m == 1;
    },
    '본문 포함 절반 이상': (q, d, rank) {
      final m = matched(q, toNfc('${d.title} ${d.summary} ${d.tags}').toLowerCase() + body(d));
      return heads(q) > 0 && m * 2 >= heads(q);
    },
    '1등은 본문 포함 절반, 나머지는 제목·요약 2개': (q, d, rank) {
      final m = matched(q, toNfc('${d.title} ${d.summary} ${d.tags}').toLowerCase() + body(d));
      return rank == 0 ? heads(q) > 0 && m * 2 >= heads(q) : isStrongMatch(q, d);
    },
  };
  print('| 규칙 | 정답 남김 (${qs.length}) | 답 없음 맞힘 (${negatives.length}) | 남긴 줄 평균 |');
  print('|---|---|---|---|');
  for (final e in rules.entries) {
    var kept = 0, empty = 0, lines = 0;
    for (final q in qs) {
      final hits = index.search(q.question, limit: 5);
      final strong = [for (final (i, d) in hits.indexed) if (e.value(q.question, d, i)) d];
      if (strong.any((d) => q.expect.contains(d.id))) kept++;
      lines += strong.length;
    }
    for (final q in negatives) {
      final hits = index.search(q, limit: 5);
      if (![for (final (i, d) in hits.indexed) if (e.value(q, d, i)) d].isNotEmpty) empty++;
    }
    print('| ${e.key} | $kept | $empty | ${(lines / qs.length).toStringAsFixed(1)} |');
  }
  exit(0);
}
