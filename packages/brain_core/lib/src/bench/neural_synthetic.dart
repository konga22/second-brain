import 'dart:math';

import '../graph/neural_layout.dart';

/// 신경망 보기 시험용 합성 지식 폴더 (설계서_프롬프트이후 5.3, 측정 M8). 앱에는 쓰지 않는다.
///
/// 시안의 makeSynthetic과 같은 모양: 주제마다 주로 나오는 대화 4~13개가 있어 노트 85%가 거기서 나오고,
/// 노트 1%는 출처가 없다. 링크는 노트 45%에 하나, 그중 75%가 같은 주제.
({List<NeuralNoteSpec> notes, List<(String, String)> links}) syntheticNeural(
  int count, {
  required int inputs,
  required int topics,
  int seed = 7,
}) {
  final rnd = Random(seed);
  final inputPaths = [
    for (var i = 0; i < inputs; i++)
      'raw/sessions/2026-${(4 + i * 7 ~/ inputs).toString().padLeft(2, '0')}-'
          '${(1 + i % 28).toString().padLeft(2, '0')}-s$i.md',
  ];
  final home = [
    for (var t = 0; t < topics; t++) [for (var j = 0; j < 4 + rnd.nextInt(10); j++) rnd.nextInt(inputs)],
  ];
  final weights = [for (var t = 0; t < topics; t++) 1 + rnd.nextInt(20)];
  final sum = weights.reduce((a, b) => a + b);
  final notes = <NeuralNoteSpec>[];
  final topicOf = <int>[];
  final byTopic = [for (var t = 0; t < topics; t++) <String>[]];
  for (var i = 0; i < count; i++) {
    var r = rnd.nextInt(sum);
    var t = 0;
    while (r >= weights[t]) {
      r -= weights[t];
      t++;
    }
    final sources = <String>[
      if (rnd.nextDouble() > 0.01)
        inputPaths[rnd.nextDouble() < 0.85 ? home[t][rnd.nextInt(home[t].length)] : rnd.nextInt(inputs)],
    ];
    final id = 'n_$i';
    notes.add(
      NeuralNoteSpec(id: id, title: '주제$t 합성 노트 $i', topic: '주제$t', isDraft: rnd.nextDouble() < 0.03, sources: sources),
    );
    topicOf.add(t);
    byTopic[t].add(id);
  }
  final links = <(String, String)>[];
  for (var i = 0; i < count; i++) {
    if (rnd.nextDouble() >= 0.45) continue;
    final t = rnd.nextDouble() < 0.75 ? topicOf[i] : rnd.nextInt(topics);
    final pool = byTopic[t];
    if (pool.isEmpty) continue;
    final other = pool[rnd.nextInt(pool.length)];
    if (other != notes[i].id) links.add((notes[i].id, other));
  }
  return (notes: notes, links: links);
}
