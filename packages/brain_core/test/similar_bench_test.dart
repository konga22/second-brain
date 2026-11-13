import 'dart:io';
import 'dart:math';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures/similar_set.dart';

/// 노트 1만 개에서 비슷한 노트 찾기 속도 (설계서_프롬프트이후 6.2: 저장 때 안내를 넣어도 빠르게).
/// `brain add`는 저장 전에 한 번, 주간 점검은 최근 노트마다 한 번 부른다.
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  const total = 10000;
  const recentCount = 300;

  setUpAll(() {
    temp = Directory.systemTemp.createTempSync('similar_bench_');
    vault = Vault(p.join(temp.path, 'SecondBrain'))..ensure();
    final random = Random(7);
    // 시험 묶음의 낱말로 문장을 만든다: 실제 노트처럼 같은 말이 여러 노트에 겹친다.
    final words = {
      for (final n in [...originals, ...duplicates, ...changed, ...related, ...unrelated, ...background])
        ...'${n.title} ${n.summary} ${n.body}'.split(RegExp(r'\s+')).where((w) => w.length > 1),
    }.toList();
    String sentence(int n) => [for (var i = 0; i < n; i++) words[random.nextInt(words.length)]].join(' ');
    final now = DateTime.now();
    final old = now.subtract(const Duration(days: 60));
    for (var i = 0; i < total; i++) {
      final id = 'n_${(i + 1).toString().padLeft(5, '0')}';
      final isRecent = i >= total - recentCount;
      final at = isRecent ? now : old;
      final path = p.join(vault.wikiDir, '주제${i % 20}', '$id.md');
      writeFileAtomic(
        path,
        Note(id: id, title: sentence(4), summary: sentence(6), body: '${sentence(30)}\n\n- ${sentence(12)}\n', created: at, updated: at)
            .toMarkdown(),
      );
      // 오래된 노트는 파일 시각도 오래됐다 (주간 점검이 파일 시각으로 먼저 거른다)
      if (!isRecent) File(path).setLastModifiedSync(old);
    }
    final watch = Stopwatch()..start();
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'))..sync();
    // ignore: avoid_print
    print('노트 $total개 처음 색인 ${watch.elapsedMilliseconds}ms');
  });

  tearDownAll(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  test('저장 전 비슷한 노트 찾기: 노트 1만 개에서 한 번 평균 30ms 아래', () {
    final notes = [
      for (final n in [...changed, ...related]) Note(id: '', title: n.title, summary: n.summary, body: n.body),
    ];
    index.similarNotes(notes.first); // 처음 한 번은 준비(조각 표)가 들어 따로 뺀다
    final times = <int>[];
    for (final note in notes) {
      final watch = Stopwatch()..start();
      index.similarNotes(note, minShared: SearchIndex.suggestMinShared);
      times.add(watch.elapsedMicroseconds);
    }
    final average = times.reduce((a, b) => a + b) / times.length / 1000;
    final most = times.reduce(max) / 1000;
    // ignore: avoid_print
    print('비슷한 노트 찾기 (1만 개, ${notes.length}번): 평균 ${average.toStringAsFixed(1)}ms, 가장 느림 ${most.toStringAsFixed(1)}ms');
    // 시험(JIT)은 앱·CLI(AOT)보다 느리다. brain add 전체(시작+저장)에 더해지는 몫이라 작아야 한다.
    expect(average, lessThan(30));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
