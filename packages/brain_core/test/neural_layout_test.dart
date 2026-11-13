import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 신경망 보기 층 배치 (설계서_프롬프트이후 5.3).
/// 입력층(대화·가져온 문서) → 은닉층(노트) → 출력층(주제), 선은 실제 관계만.
void main() {
  NeuralNoteSpec note(String id, String topic, List<String> sources, {bool draft = false, String? title}) =>
      NeuralNoteSpec(id: id, title: title ?? '노트 $id', topic: topic, isDraft: draft, sources: sources);

  group('층과 선', () {
    final notes = [
      note('n1', '결제', ['raw/sessions/2026-11-01-aaaa.md']),
      note('n2', '결제', ['raw/sessions/2026-11-02-bbbb.md', 'raw/sessions/2026-11-02-bbbb.md']), // 같은 출처 두 번
      note('n3', '배포', ['raw/imports/2026-11-07-참고레포_조사.md'], draft: true),
      note('n4', '배포', []), // 출처 없음
      note('n5', '맥', ['/Users/x/.claude/projects/a/b.jsonl', 'raw/sessions/2026-11-01-aaaa.md']), // jsonl은 입력층이 아니다
    ];
    final links = [('n1', 'n3'), ('n1', 'n2'), ('n3', 'n1'), ('n4', 'n5'), ('n1', 'n1'), ('n1', '없는노트')];
    final layout = layoutNeural(notes, links, inputTitles: {'raw/sessions/2026-11-01-aaaa.md': '사이드 채팅'});

    test('노드 수: 입력 = 실제 대화·문서, 은닉 = 노트, 출력 = 주제', () {
      expect(layout.inputs.length, 3);
      expect(layout.notes.length, 5);
      expect(layout.topics.length, 3);
      expect(layout.topics.map((t) => t.count).reduce((a, b) => a + b), 5);
    });

    test('입력 종류와 이름: 대화는 동그라미, 가져온 문서는 마름모. 이름이 없으면 파일 이름', () {
      final byPath = {for (final i in layout.inputs) i.path: i};
      expect(byPath['raw/sessions/2026-11-01-aaaa.md']!.kind, NeuralInputKind.session);
      expect(byPath['raw/sessions/2026-11-01-aaaa.md']!.title, '사이드 채팅');
      expect(byPath['raw/imports/2026-11-07-참고레포_조사.md']!.kind, NeuralInputKind.document);
      expect(byPath['raw/imports/2026-11-07-참고레포_조사.md']!.title, '2026-11-07-참고레포_조사');
      expect(byPath['raw/sessions/2026-11-01-aaaa.md']!.date, '2026-11-01');
    });

    test('선: 출처 중복·자기 링크·없는 노트 링크는 빼고, 이웃 주제는 자기 주제가 아닐 때만', () {
      final n1 = layout.notes[layout.indexOfNote('n1')!];
      final n2 = layout.notes[layout.indexOfNote('n2')!];
      final n4 = layout.notes[layout.indexOfNote('n4')!];
      final n5 = layout.notes[layout.indexOfNote('n5')!];
      expect(n2.inputs.length, 1);
      expect(n4.inputs, isEmpty);
      expect(n5.inputs.length, 1);
      expect(n1.neighborTopics.map((t) => layout.topics[t].name), ['배포']);
      expect(n4.neighborTopics.map((t) => layout.topics[t].name), ['맥']);
      expect(layout.sourceEdgeCount, 4);
      expect(layout.faintEdgeCount, 4); // n1→배포, n3→결제, n4→맥, n5→배포
      expect(layout.notes[layout.indexOfNote('n3')!].isDraft, isTrue);
    });

    test('입력 → 노트 역방향 목록이 노트 쪽과 맞는다', () {
      for (var i = 0; i < layout.inputs.length; i++) {
        for (final n in layout.inputs[i].notes) {
          expect(layout.notes[n].inputs, contains(i));
        }
      }
      final total = layout.inputs.map((i) => i.notes.length).reduce((a, b) => a + b);
      expect(total, layout.sourceEdgeCount);
    });
  });

  test('빈 지식 폴더도 오류 없이 빈 배치', () {
    final layout = layoutNeural(const [], const []);
    expect(layout.notes, isEmpty);
    expect(layout.inputs, isEmpty);
    expect(layout.topics, isEmpty);
  });

  group('순서', () {
    final data = syntheticNeural(800, inputs: 40, topics: 9, seed: 3);
    final layout = layoutNeural(data.notes, data.links);

    test('노트 순서는 빠짐·중복 없는 순열이고, 같은 주제는 한 덩어리로 붙어 있다', () {
      expect(layout.notes.map((n) => n.id).toSet().length, data.notes.length);
      expect(layout.notes.map((n) => n.id).toSet(), data.notes.map((n) => n.id).toSet());
      // 주제 덩어리: 주제 순서대로 [start, start+count)
      var at = 0;
      for (var t = 0; t < layout.topics.length; t++) {
        expect(layout.topics[t].start, at);
        for (var i = at; i < at + layout.topics[t].count; i++) {
          expect(layout.notes[i].topic, t);
        }
        at += layout.topics[t].count;
      }
      expect(at, layout.notes.length);
      expect(layout.inputs.map((i) => i.path).toSet().length, layout.inputs.length);
      expect(layout.topics.map((t) => t.name).toSet().length, layout.topics.length);
    });

    test('선 겹침이 정리 전(날짜순·파일순·이름순)보다 줄어든다', () {
      expect(layout.naive.total, greaterThan(0));
      expect(layout.crossings.inputNote, lessThan(layout.naive.inputNote ~/ 2),
          reason: '대화 → 노트 ${layout.naive.inputNote} → ${layout.crossings.inputNote}');
      expect(layout.crossings.total, lessThan(layout.naive.total),
          reason: '전체 ${layout.naive.total} → ${layout.crossings.total}');
    });

    test('같은 입력이면 같은 순서 (다시 그려도 노트가 자리를 바꾸지 않는다)', () {
      final again = layoutNeural(data.notes, data.links);
      expect(again.notes.map((n) => n.id).toList(), layout.notes.map((n) => n.id).toList());
      expect(again.inputs.map((n) => n.path).toList(), layout.inputs.map((n) => n.path).toList());
    });
  });

  test('겹침 세기: 작은 예를 손으로 센 값과 같다', () {
    // u0→v1, u1→v0 은 한 번 겹친다. 같은 끝을 나누는 선은 겹침이 아니다.
    expect(countLayerCrossings([0, 1], [1, 0], 2), 1);
    expect(countLayerCrossings([0, 0, 1], [0, 1, 1], 2), 0);
    expect(countLayerCrossings([0, 1, 2], [2, 1, 0], 3), 3);
  });

  test('M8: 노트 1만 개 층 배치 시간 (목표 첫 표시 1초 안)', () {
    final data = syntheticNeural(10000, inputs: 160, topics: 13, seed: 11);
    layoutNeural(data.notes, data.links); // 데우기 (JIT)
    final watch = Stopwatch()..start();
    final layout = layoutNeural(data.notes, data.links);
    watch.stop();
    // ignore: avoid_print
    print('[M8] 노트 1만 개 층 배치 ${watch.elapsedMilliseconds}ms · 입력 ${layout.inputs.length} · 주제 ${layout.topics.length}'
        ' · 선 ${layout.sourceEdgeCount}/${layout.notes.length}/${layout.faintEdgeCount}'
        ' · 겹침 ${layout.naive.inputNote}→${layout.crossings.inputNote}, ${layout.naive.noteTopic}→${layout.crossings.noteTopic}');
    expect(layout.notes.length, 10000);
    expect(watch.elapsedMilliseconds, lessThan(600), reason: '배치만으로 1초 목표의 절반 넘게 쓰면 안 된다');
  });

  group('지식 폴더에서 읽기', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('neural_'));
    tearDown(() => dir.deleteSync(recursive: true));

    void write(String rel, String text) {
      final f = File(p.join(dir.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(text);
    }

    test('노트 머리말의 sources와 원본 제목·id를 읽는다 (한 줄·여러 줄 목록 모두)', () {
      write('raw/sessions/2026-10-02-bed8445f.md',
          '---\nid: r_bed8445f\ntitle: "세션 bed8445f 사이드 채팅"\nsources: ["/x/a.jsonl"]\n---\n본문');
      write('raw/imports/2026-11-07-참고레포_조사.md', '---\ntitle: "참고레포_조사"\nsource: import\n---\n# 참고');
      write('wiki/결제/a.md', '---\nid: n_1\ntitle: "가"\nsources: ["raw/sessions/2026-10-02-bed8445f.md"]\n---\n본문');
      write('wiki/결제/b.md', '---\nid: n_2\ntitle: "나"\nsources:\n  - raw/imports/2026-11-07-참고레포_조사.md\n  - "raw/sessions/2026-10-02-bed8445f.md"\nstatus: draft\n---\n');
      write('wiki/c.md', '머리말 없는 노트');
      final layout = neuralLayoutFromVault(dir.path, [
        (id: 'n_1', path: 'wiki/결제/a.md', title: '가', topic: '결제', isDraft: false),
        (id: 'n_2', path: 'wiki/결제/b.md', title: '나', topic: '결제', isDraft: true),
        (id: 'n_3', path: 'wiki/c.md', title: '다', topic: '미분류', isDraft: false),
        (id: 'n_4', path: 'wiki/없는파일.md', title: '라', topic: '미분류', isDraft: false),
      ], const []);
      expect(layout.notes.length, 4);
      expect(layout.inputs.length, 2);
      final session = layout.inputs.firstWhere((i) => i.kind == NeuralInputKind.session);
      expect(session.title, '사이드 채팅');
      expect(session.rawId, 'r_bed8445f');
      expect(session.notes.length, 2);
      final doc = layout.inputs.firstWhere((i) => i.kind == NeuralInputKind.document);
      expect(doc.title, '참고레포_조사');
      expect(layout.notes[layout.indexOfNote('n_2')!].inputs.length, 2);

      // 색인의 원본 문서를 넘기면 그 id·제목을 쓴다 (가져온 문서는 머리말에 id가 없다)
      final withIndex = neuralLayoutFromVault(dir.path, [
        (id: 'n_2', path: 'wiki/결제/b.md', title: '나', topic: '결제', isDraft: true),
      ], const [], rawDocs: {'raw/imports/2026-11-07-참고레포_조사.md': (id: 'r_abc', title: '참고레포_조사')});
      final imported = withIndex.inputs.firstWhere((i) => i.kind == NeuralInputKind.document);
      expect(imported.rawId, 'r_abc');
      expect(withIndex.indexOfRaw('r_abc'), withIndex.inputs.indexOf(imported));
    });

    test('M8: 노트 1만 개 파일 읽기 + 배치 (첫 표시까지 앱이 하는 일)', () {
      final data = syntheticNeural(10000, inputs: 160, topics: 13, seed: 5);
      final specs = <({String id, String path, String title, String topic, bool isDraft})>[];
      for (final n in data.notes) {
        final rel = 'wiki/${n.topic}/${n.id}.md';
        write(rel, '---\nid: ${n.id}\ntitle: "${n.title}"\nsummary: "요약"\ntags: []\naliases: []\nsource: session\n'
            'sources: [${n.sources.map((s) => '"$s"').join(', ')}]\nstatus: active\n---\n\n본문 ${n.id}\n');
        specs.add((id: n.id, path: rel, title: n.title, topic: n.topic, isDraft: n.isDraft));
      }
      for (final s in {for (final n in data.notes) ...n.sources}) {
        write(s, '---\nid: r_${p.basenameWithoutExtension(s)}\ntitle: "세션 x 합성 대화"\n---\n');
      }
      final watch = Stopwatch()..start();
      final layout = neuralLayoutFromVault(dir.path, specs, data.links);
      watch.stop();
      // ignore: avoid_print
      print('[M8] 노트 1만 개 파일 읽기 + 층 배치 ${watch.elapsedMilliseconds}ms (첫 실행, JIT)');
      expect(layout.notes.length, 10000);
      expect(layout.sourceEdgeCount, data.notes.fold<int>(0, (s, n) => s + n.sources.length));
    });
  });
}
