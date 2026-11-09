import 'package:yaml/yaml.dart';

import '../lessons/lesson_store.dart';

/// 규칙 매칭 시험 한 묶음 (`bench/lessons.yaml`, 기능검토 2절·실수 노트 L-0008).
/// [lesson]이 null이면 어느 규칙에도 걸리면 안 되는 요청 묶음(none)이다.
class LessonCase {
  const LessonCase(this.lesson, this.hit, this.miss);

  final String? lesson;

  /// 걸려야 할 요청 (trigger와 다른 말, 사용자 말투).
  final List<String> hit;

  /// 같은 단어가 있어도 걸리면 안 되는 요청.
  final List<String> miss;

  /// `- lesson: L-0003\n  hit: [...]\n  miss: [...]`, `- none: [...]`
  static List<LessonCase> parseYaml(String text) {
    final yaml = loadYaml(text);
    if (yaml is! YamlList) return const [];
    List<String> list(Object? v) => [for (final s in (v as YamlList? ?? YamlList())) '$s'];
    return [
      for (final item in yaml.whereType<YamlMap>())
        if (item.containsKey('none'))
          LessonCase(null, const [], list(item['none']))
        else
          LessonCase('${item['lesson']}', list(item['hit']), list(item['miss'])),
    ];
  }
}

class LessonBenchResult {
  const LessonBenchResult({
    required this.hitTotal,
    required this.hitOk,
    required this.missTotal,
    required this.missWrong,
    required this.noneTotal,
    required this.noneWrong,
    required this.otherWrong,
    required this.unmatched,
    required this.wrong,
  });

  /// 걸려야 할 요청 수와 그중 그 규칙이 걸린 수.
  final int hitTotal;
  final int hitOk;

  /// 걸리면 안 될 요청 수와 그중 그 규칙이 걸린 수 (헛걸림).
  final int missTotal;
  final int missWrong;

  /// 어느 규칙에도 걸리면 안 될 요청 수와 그중 무엇이든 걸린 수.
  final int noneTotal;
  final int noneWrong;

  /// hit·miss 요청에서 **다른** 규칙이 걸린 수 (헛걸림).
  final int otherWrong;

  /// 안 걸린 hit: `L-0003  요청`
  final List<String> unmatched;

  /// 잘못 걸린 것: `L-0002 ← 요청`
  final List<String> wrong;

  double get hitRate => hitTotal == 0 ? 0 : hitOk / hitTotal;
  double get missRate => missTotal == 0 ? 0 : missWrong / missTotal;
  double get noneRate => noneTotal == 0 ? 0 : noneWrong / noneTotal;
}

/// 요청마다 [LessonStore.match]가 붙이는 규칙을 잰다. 돈이 들지 않는 결정적인 시험이다.
LessonBenchResult runLessonBench(LessonStore store, List<LessonCase> cases) {
  var hitTotal = 0, hitOk = 0, missTotal = 0, missWrong = 0, noneTotal = 0, noneWrong = 0, otherWrong = 0;
  final unmatched = <String>[];
  final wrong = <String>[];
  for (final c in cases) {
    if (c.lesson == null) {
      for (final text in c.miss) {
        noneTotal++;
        final ids = [for (final l in store.match(text)) l.id];
        if (ids.isNotEmpty) {
          noneWrong++;
          wrong.add('${ids.join(',')} ← $text');
        }
      }
      continue;
    }
    for (final text in c.hit) {
      hitTotal++;
      final ids = [for (final l in store.match(text)) l.id];
      if (ids.contains(c.lesson)) {
        hitOk++;
      } else {
        unmatched.add('${c.lesson}  $text');
      }
      for (final id in ids.where((id) => id != c.lesson)) {
        otherWrong++;
        wrong.add('$id ← $text');
      }
    }
    for (final text in c.miss) {
      missTotal++;
      final ids = [for (final l in store.match(text)) l.id];
      if (ids.contains(c.lesson)) {
        missWrong++;
        wrong.add('${c.lesson} ← $text');
      }
      for (final id in ids.where((id) => id != c.lesson)) {
        otherWrong++;
        wrong.add('$id ← $text');
      }
    }
  }
  return LessonBenchResult(
    hitTotal: hitTotal,
    hitOk: hitOk,
    missTotal: missTotal,
    missWrong: missWrong,
    noneTotal: noneTotal,
    noneWrong: noneWrong,
    otherWrong: otherWrong,
    unmatched: unmatched,
    wrong: wrong,
  );
}
