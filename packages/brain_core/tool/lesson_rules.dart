// 규칙 매칭 방식 비교 (2026-11-09, 기능검토 2절·실수 노트 L-0008). 돈 안 듦.
// dart run tool/lesson_rules.dart <지식 폴더> <bench/lessons.yaml>
// 고르는 기준(재기 전에 정함): 헛걸림(걸리면 안 될 요청에 그 규칙) 10% 이하, 관계없는 요청 0번 중 걸림이 가장 높은 것.
import 'dart:io';

import 'package:brain_core/brain_core.dart';

typedef Matcher = List<String> Function(String prompt);

void main(List<String> args) {
  final vault = Vault(args[0]);
  final index = SearchIndex.open(vault)..sync();
  final store = LessonStore(vault, index);
  final cases = LessonCase.parseYaml(File(args[1]).readAsStringSync());
  final lessons = store.all(status: LessonStatus.active);

  int heads(String text, String target) {
    final t = toNfc(target).toLowerCase();
    return LessonStore.wordHeads(text).where(t.contains).length;
  }

  final matchers = <String, Matcher>{
    'S0 지금 (trigger 단어 머리 50%)': (q) => [for (final l in store.match(q)) l.id],
    'S1 trigger+행동에 단어 머리 2개': (q) => [
      for (final l in lessons)
        if (heads(q, '${l.trigger} ${l.action}') >= 2) l.id,
    ],
    'S2 trigger+행동+diff에 단어 머리 2개': (q) => [
      for (final l in lessons)
        if (heads(q, '${l.trigger} ${l.action} ${l.diff}') >= 2) l.id,
    ],
    'S3 2글자 조각 검색(실수 노트만) 1등 + 단어 머리 2개': (q) {
      final docs = index.search(q, limit: 1, kinds: {'lesson'});
      return [
        for (final d in docs)
          if (lessons.any((l) => l.id == d.id && heads(q, '${l.trigger} ${l.action} ${l.diff}') >= 2)) d.id,
      ];
    },
    'S4 S0 또는 S1': (q) => {
      for (final l in store.match(q)) l.id,
      for (final l in lessons)
        if (heads(q, '${l.trigger} ${l.action}') >= 2) l.id,
    }.toList(),
  };

  for (final entry in matchers.entries) {
    var hit = 0, hitN = 0, miss = 0, missN = 0, other = 0, none = 0, noneN = 0;
    for (final c in cases) {
      if (c.lesson == null) {
        for (final q in c.miss) {
          noneN++;
          if (entry.value(q).isNotEmpty) none++;
        }
        continue;
      }
      for (final q in c.hit) {
        hitN++;
        final ids = entry.value(q);
        if (ids.contains(c.lesson)) hit++;
        other += ids.where((id) => id != c.lesson).length;
      }
      for (final q in c.miss) {
        missN++;
        final ids = entry.value(q);
        if (ids.contains(c.lesson)) miss++;
        other += ids.where((id) => id != c.lesson).length;
      }
    }
    stdout.writeln('${entry.key}: 걸림 $hit/$hitN, 헛걸림 $miss/$missN, 다른 규칙 $other번, 관계없는 요청 $none/$noneN');
  }
  index.close();
}
