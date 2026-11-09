// 미리 넣기(R2) 기준 비교 (2026-11-09, 기능검토 K-09). 돈 안 듦.
// dart run tool/inject_rules.dart <지식 폴더> <bench/questions.yaml,bench/questions_casual.yaml> <bench/lessons.yaml>
// 고르는 기준(재기 전에 정함): 질문 세트마다 미리 넣는 질문 수가 V0보다 1개 넘게 줄지 않고,
// 알려진 엉뚱한 사례(K-09)와 관계없는 요청(none)에는 0개.
// hook_command.dart relatedNotes와 같은 계산을 여기서 다시 한다(만들기 말 빼기 포함).
import 'dart:io';

import 'package:brain_core/brain_core.dart';

const buildWords = {'만들', '구현', '개발', '추가', '똑같', '해줘', '싶어', '어떻', '어떤', '이거', '그거', '기능'};

// 11/08~09에 실제로 본 엉뚱한 미리 넣기 (기능검토 K-09)
const known = [
  '포트 8080을 다른 앱 프로세스가 잡고 있어서 내 서버가 안 켜져. 그 프로세스 끄고 다시 켜 줘. 아직 손대지 말고, 어떻게 할지 순서만 3줄로 말해 줘.',
  '앱에 화면 배율(⌘+/⌘-) 기능을 넣으려고 해. 아직 손대지 말고, 어떻게 할지 순서만 3줄로 말해 줘.',
  '근데 이것에 대해서 배운게 없어? 세컨드 브래인에 안들어왔는데 ,, 아님 이미 있는거야? 결국은 초반에 설계측면에서 찾은 약점이라 이제와서 고친거잖아',
];

void main(List<String> args) {
  final vault = Vault(args[0]);
  final index = SearchIndex.open(vault)..sync();
  final questionFiles = args[1].split(',');
  final cases = LessonCase.parseYaml(File(args[2]).readAsStringSync());
  final none = [for (final c in cases) if (c.lesson == null) ...c.miss];
  final tasks = [for (final c in cases) if (c.lesson != null) ...c.hit, for (final c in cases) if (c.lesson != null) ...c.miss];

  List<String> headsOf(String prompt, {bool dropQuestion = false}) {
    final text = dropQuestion
        ? toNfc(prompt).replaceAll(RegExp(r'[?？!.,]'), ' ').split(RegExp(r'\s+')).where((t) => t.isNotEmpty && !isQuestionWord(t)).join(' ')
        : prompt;
    return LessonStore.wordHeads(text).where((h) => !buildWords.contains(h)).toList();
  }

  // 방식: (프롬프트, 노트, 맞은 수, 단어 머리 수) → 넣나
  final variants = <String, bool Function(List<String> heads, int matched)>{
    'V0 지금까지(2개 이상)': (h, m) => m >= 2 || h.length == 1 && m == 1,
    'V1 + 비율 25%': (h, m) => (m >= 2 || h.length == 1 && m == 1) && m / h.length >= 0.25,
    'V3 + 긴 요청(단어 머리 12개 이상)만 비율 25%': (h, m) => (m >= 2 || h.length == 1 && m == 1) && (h.length < 12 || m / h.length >= 0.25),
  };
  final dropFor = {'V2 + 묻는 말 빼고 비율 25%': true};

  List<IndexedDoc> related(String prompt, bool Function(List<String>, int) rule, {bool drop = false}) {
    final heads = headsOf(prompt, dropQuestion: drop);
    if (heads.isEmpty) return const [];
    final out = <IndexedDoc>[];
    for (final doc in index.search(prompt, limit: 8)) {
      final text = toNfc('${doc.title} ${doc.summary} ${doc.tags}').toLowerCase();
      final matched = heads.where(text.contains).length;
      if (rule(heads, matched)) out.add(doc);
      if (out.length >= 3) break;
    }
    return out;
  }

  final runs = <String, (bool Function(List<String>, int), bool)>{
    for (final e in variants.entries) e.key: (e.value, false),
    for (final e in dropFor.keys) e: (variants['V1 + 비율 25%']!, true),
  };
  for (final file in questionFiles) {
    final questions = BenchQuestion.parseYaml(File(file).readAsStringSync());
    stdout.writeln('== ${file.split('/').last} (${questions.length}개)');
    for (final r in runs.entries) {
      final (rule, drop) = r.value;
      var qInjected = 0, qCorrect = 0, qExtra = 0, negInjected = 0;
      for (final q in questions) {
        final docs = related(q.question, rule, drop: drop);
        if (q.expect.isEmpty) {
          if (docs.isNotEmpty) negInjected++;
          continue;
        }
        if (docs.isEmpty) continue;
        qInjected++;
        if (docs.any((d) => q.expect.contains(d.id))) qCorrect++;
        qExtra += docs.where((d) => !q.expect.contains(d.id)).length;
      }
      final pos = questions.where((q) => q.expect.isNotEmpty).length;
      final knownHits = known.where((k) => related(k, rule, drop: drop).isNotEmpty).length;
      final noneHits = none.where((t) => related(t, rule, drop: drop).isNotEmpty).length;
      final taskHits = tasks.where((t) => related(t, rule, drop: drop).isNotEmpty).length;
      stdout.writeln('${r.key}: 답 있는 질문 $pos개 중 넣음 $qInjected(정답 포함 $qCorrect, 정답 밖 $qExtra), 답 없는 질문에 넣음 $negInjected · '
          '알려진 엉뚱한 사례 $knownHits/${known.length} · 관계없는 요청 $noneHits/${none.length} · 작업 요청 $taskHits/${tasks.length}');
    }
  }
  for (final k in known) {
    stdout.writeln('알려진 사례 단어 머리 ${headsOf(k).length}개 (묻는 말 빼면 ${headsOf(k, dropQuestion: true).length}개)');
  }
  index.close();
}
