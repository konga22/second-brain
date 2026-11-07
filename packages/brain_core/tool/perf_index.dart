// 색인 성능 측정 (설계서 5.8 노트 1만 개). dart run tool/perf_index.dart <지식 폴더> [rebuild]
import 'dart:io';

import 'package:brain_core/brain_core.dart';

void main(List<String> args) {
  final vault = Vault(args.first);
  final w = Stopwatch()..start();
  final index = SearchIndex.open(vault);
  print('열기 ${w.elapsedMilliseconds}ms');
  if (args.length > 1 && args[1] == 'rebuild') {
    w.reset();
    final r = index.rebuild();
    print('다시 만들기 ${w.elapsedMilliseconds}ms (${r.added}개)');
  }
  for (var i = 0; i < 3; i++) {
    w.reset();
    index.sync();
    final s = w.elapsedMilliseconds;
    w.reset();
    final hits = index.search('결제 웹훅 재시도', limit: 5);
    print('동기화(변경 없음) ${s}ms · 검색 ${w.elapsedMilliseconds}ms (${hits.length}개)');
  }
  w.reset();
  index.notes();
  print('notes() ${w.elapsedMilliseconds}ms');
  w.reset();
  index.links();
  print('links() ${w.elapsedMilliseconds}ms');
  w.reset();
  final sample = index.notes().take(100).toList();
  var kt = 0;
  for (final d in sample) {
    final f = File('${vault.root}/${d.path}');
    final note = Note.parse(f.readAsStringSync(), fallbackId: '', fallbackTitle: d.title);
    final w2 = Stopwatch()..start();
    index.keyTerms(note);
    kt += w2.elapsedMicroseconds;
  }
  print('노트 100개: 전체 ${w.elapsedMilliseconds}ms, 그중 keyTerms ${kt ~/ 1000}ms');
  for (final (name, fn) in <(String, Object? Function())>[
    ('Linter.run', () => Linter(vault, index).run()),
    ('LessonStore.all', () => LessonStore(vault, index).all()),
    ('TodoStore.candidatesFromNotes', () => TodoStore(vault, index).candidatesFromNotes()),
    ('TodoStore.fromNotes', () => TodoStore(vault, index).fromNotes()),
    ('topics()', () => index.topics()),
    ('docsOf(raw)', () => index.docsOf('raw')),
    ('graphPositions()', () => index.graphPositions()),
  ]) {
    w.reset();
    fn();
    print('$name ${w.elapsedMilliseconds}ms');
  }
  exit(0);
}
