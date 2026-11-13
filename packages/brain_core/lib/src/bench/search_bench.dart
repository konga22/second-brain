import 'package:yaml/yaml.dart';

import '../index/search_index.dart';

/// `brain bench` 질문 하나: 질문 → 찾아야 할 노트 id.
class BenchQuestion {
  const BenchQuestion(this.question, this.expect);

  final String question;
  final List<String> expect;

  /// `bench/questions.yaml`: `- q: 질문\n  expect: [n_0001]`
  static List<BenchQuestion> parseYaml(String text) {
    final yaml = loadYaml(text);
    if (yaml is! YamlList) return const [];
    return [
      for (final item in yaml.whereType<YamlMap>())
        BenchQuestion('${item['q']}', [
          for (final id in (item['expect'] as YamlList? ?? YamlList())) '$id',
        ]),
    ];
  }
}

class BenchResult {
  const BenchResult({
    required this.count,
    required this.recallAt5,
    required this.mrr,
    required this.averageMs,
    required this.averageChars,
    required this.misses,
  });

  final int count;

  /// 정답이 상위 5개 안에 든 비율.
  final double recallAt5;

  /// 첫 정답 순위의 역수 평균.
  final double mrr;
  final double averageMs;

  /// `find` 출력 글자 수 평균 (토큰 어림).
  final double averageChars;

  /// 상위 5개에 정답이 없던 질문.
  final List<String> misses;
}

/// 검색 품질·속도 측정 (설계서 5.8).
BenchResult runBench(
  SearchIndex index,
  List<BenchQuestion> questions, {
  String Function(IndexedDoc)? formatLine,
}) {
  var hits = 0;
  var reciprocal = 0.0;
  var micros = 0;
  var chars = 0;
  final misses = <String>[];
  for (final q in questions) {
    final watch = Stopwatch()..start();
    final results = index.search(q.question, limit: 5);
    micros += watch.elapsedMicroseconds;
    chars += results
        .map((d) => formatLine?.call(d) ?? '${d.id}  ${d.title} — ${d.summary}  ${d.folder}')
        .join('\n')
        .length;
    final rank = results.indexWhere((d) => q.expect.contains(d.id));
    if (rank >= 0) {
      hits++;
      reciprocal += 1 / (rank + 1);
    } else {
      misses.add(q.question);
    }
  }
  final n = questions.isEmpty ? 1 : questions.length;
  return BenchResult(
    count: questions.length,
    recallAt5: hits / n,
    mrr: reciprocal / n,
    averageMs: micros / n / 1000,
    averageChars: chars / n,
    misses: misses,
  );
}
