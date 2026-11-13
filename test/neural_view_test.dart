import 'dart:io';
import 'dart:math';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:secondbrain/app/theme/app_theme.dart';
import 'package:secondbrain/core/background_tasks.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:secondbrain/features/home/graph_view.dart';
import 'package:secondbrain/features/home/neural_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 신경망 보기 (설계서_프롬프트이후 5.3). 그림은 사람이 봐야 해서, 여기서는 전환·고르기·이름표 글자만 본다.
void main() {
  const longTitle = 'Claude Code 압축 훅 3가지 — 압축 전 지시·압축 요약 받기·압축 뒤 주입까지 한 번에 정리한 노트 제목';
  final specs = [
    const NeuralNoteSpec(id: 'n_1', title: '결제 웹훅 재시도', topic: '결제', sources: ['raw/sessions/2026-11-01-aaaa.md']),
    const NeuralNoteSpec(id: 'n_2', title: longTitle, topic: '결제', isDraft: true, sources: ['raw/sessions/2026-11-01-aaaa.md']),
    const NeuralNoteSpec(id: 'n_3', title: '배포 체크리스트', topic: '배포', sources: ['raw/imports/2026-11-07-참고.md']),
    const NeuralNoteSpec(id: 'n_4', title: '도메인 연결', topic: '배포', sources: ['raw/sessions/2026-11-02-bbbb.md']),
    const NeuralNoteSpec(id: 'n_5', title: '출처 없는 노트', topic: '결제'),
  ];
  final layout = layoutNeural(
    specs,
    const [('n_1', 'n_3')],
    inputTitles: const {'raw/sessions/2026-11-01-aaaa.md': '사이드 채팅'},
    inputRawIds: const {'raw/sessions/2026-11-01-aaaa.md': 'r_aaaa'},
  );

  IndexedDoc doc(NeuralNoteSpec s) => IndexedDoc(
    id: s.id,
    path: 'wiki/${s.topic}/${s.title}.md',
    kind: 'note',
    title: s.title,
    summary: '',
    tags: '',
    status: s.isDraft ? NoteStatus.draft : NoteStatus.active,
    mtime: DateTime(2026, 11, 13),
    hash: 'h',
  );

  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, Widget child, {NeuralLayout? using}) async {
    tester.view.physicalSize = const Size(1000, 700) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    container = ProviderContainer(
      overrides: [
        neuralLayoutProvider.overrideWith((ref) async => using ?? layout),
        notesProvider.overrideWithValue([for (final s in specs) doc(s)]),
        linksProvider.overrideWithValue(const [NoteLink(fromId: 'n_1', toId: 'n_3', kind: 'link')]),
        graphLayoutProvider.overrideWith(
          (ref) async => {for (var i = 0; i < specs.length; i++) specs[i].id: Point(i * 80.0, (i % 2) * 60.0)},
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          theme: buildAppTheme(Brightness.dark),
          home: SizedBox(width: 1000, height: 700, child: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// _Geo와 같은 셈 (영역 1000×700): 층 위 92, 높이 560, 입력 x 200, 은닉 x 515, 출력 x 830.
  Offset noteAt(String id) => Offset(515, 92 + (layout.indexOfNote(id)! + 0.5) * 560 / layout.notes.length);
  Offset inputAt(int i) => Offset(200, 92 + (i + 0.5) * 560 / layout.inputs.length);
  Offset topicAt(int t) => Offset(830, 92 + (t + 0.5) * 560 / layout.topics.length);

  testWidgets('그래프 보기의 [그물 | 신경망] 전환: 그물 보기는 그대로 두고 바꿔 보인다', (tester) async {
    await pump(tester, const GraphView());
    expect(find.byType(NeuralView), findsNothing);
    expect(find.text('모든 폴더'), findsOneWidget);
    await tester.tap(find.text('신경망'));
    await tester.pumpAndSettle();
    expect(find.byType(NeuralView), findsOneWidget);
    expect(find.text('모든 폴더'), findsNothing);
    expect(find.text('대화·문서 3 · 노트 5 · 주제 2'), findsOneWidget);
    await tester.tap(find.text('그물'));
    await tester.pumpAndSettle();
    expect(find.byType(NeuralView), findsNothing);
    expect(find.text('모든 폴더'), findsOneWidget);
  });

  testWidgets('고르기: 노트는 오른쪽 패널에 열고, 대화는 원본을 열고, 주제는 길만 밝힌다. 빈 곳·Esc는 해제', (tester) async {
    await pump(tester, NeuralView(toggle: const SizedBox()));
    await tester.tapAt(noteAt('n_4'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteProvider), 'n_4');

    final session = layout.inputs.indexWhere((i) => i.rawId == 'r_aaaa');
    await tester.tapAt(inputAt(session));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteProvider), 'r_aaaa');

    // 주제: 패널은 그대로, 그 주제 노트의 이름표가 밝게 (노트가 적어 모두)
    neuralLabelLog.clear();
    final pay = layout.topics.indexWhere((t) => t.name == '결제');
    await tester.tapAt(topicAt(pay));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteProvider), 'r_aaaa');
    final texts = neuralLabelLog.map((l) => l.text).toSet();
    expect(texts, containsAll(['결제 웹훅 재시도', '출처 없는 노트', '결제  3']));

    // 다른 곳에서 노트를 열면(목록 등) 그 노트로 바뀐다
    container.read(selectedNoteProvider.notifier).select('n_1');
    await tester.pumpAndSettle();
    neuralLabelLog.clear();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.tapAt(const Offset(515, 30)); // 층 밖 빈 곳
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteProvider), isNull);

    await tester.tapAt(noteAt('n_3'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteProvider), 'n_3');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteProvider), isNull);
  });

  testWidgets('이름표는 자르지 않는다: 긴 제목은 여러 줄로 다 보인다 (결정 6)', (tester) async {
    await pump(tester, NeuralView(toggle: const SizedBox()));
    // 마우스를 올리면 이름 전체 (말줄임 없음)
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    neuralLabelLog.clear();
    await mouse.moveTo(noteAt('n_2'));
    await tester.pumpAndSettle();
    expect(find.text(longTitle), findsOneWidget, reason: '마우스 올림 안내에 제목 전체');
    final hovered = neuralLabelLog.where((l) => l.text == longTitle);
    expect(hovered, isNotEmpty, reason: '노드 옆 이름표도 제목 전체');
    expect(hovered.first.lines, greaterThan(1), reason: '긴 제목은 줄을 바꾼다');
    expect(neuralLabelLog.any((l) => l.text.contains('…')), isFalse);
    await mouse.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();

    // 고르면 고른 길의 노트 이름표도 전체
    await tester.tapAt(noteAt('n_2'));
    await tester.pumpAndSettle();
    expect(neuralLabelLog.where((l) => l.text == longTitle && l.lines > 1), isNotEmpty);

    // 확대하면 노트 이름표가 바탕에 나온다 (모두 전체 제목)
    container.read(selectedNoteProvider.notifier).select(null);
    await tester.pumpAndSettle();
    neuralLabelLog.clear();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('+'));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final shown = neuralLabelLog.map((l) => l.text).toSet();
    expect(shown, contains(longTitle));
    expect(shown.where((t) => t.endsWith('…')), isEmpty);
  });

  testWidgets('확대는 은닉층만: 휠로 키워도 대화·주제 자리는 그대로이고 [맞추기]로 돌아온다', (tester) async {
    await pump(tester, NeuralView(toggle: const SizedBox()));
    final topicPoint = topicAt(0);
    await tester.sendEventToBinding(
      PointerScrollEvent(position: noteAt('n_1'), scrollDelta: const Offset(0, -600), kind: PointerDeviceKind.mouse),
    );
    await tester.pumpAndSettle();
    // 주제 자리는 그대로라 같은 곳을 누르면 같은 주제가 골라진다 (패널은 안 바뀜) → 노트 자리는 바뀜
    neuralLabelLog.clear();
    await tester.tapAt(topicPoint);
    await tester.pumpAndSettle();
    expect(neuralLabelLog.map((l) => l.text), contains('${layout.topics[0].name}  ${layout.topics[0].count}'));
    await tester.tap(find.text('맞추기'));
    await tester.pumpAndSettle();
    await tester.tapAt(noteAt('n_5'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteProvider), 'n_5');
  });

  testWidgets('M8: 노트 1만 개 첫 표시 시간 (파일 읽기·배치 isolate + 첫 그리기)', (tester) async {
    final dir = Directory.systemTemp.createTempSync('neural_m8_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final data = syntheticNeural(10000, inputs: 160, topics: 13, seed: 5);
    final rows = <NeuralNoteRow>[];
    await tester.runAsync(() async {
      for (final n in data.notes) {
        final rel = 'wiki/${n.topic}/${n.id}.md';
        final f = File(p.join(dir.path, rel))..parent.createSync(recursive: true);
        f.writeAsStringSync('---\nid: ${n.id}\ntitle: "${n.title}"\nsummary: "요약"\ntags: []\naliases: []\n'
            'source: session\nsources: [${n.sources.map((s) => '"$s"').join(', ')}]\nstatus: active\n---\n\n본문\n');
        rows.add((id: n.id, path: rel, title: n.title, topic: n.topic, isDraft: n.isDraft));
      }
      for (final s in {for (final n in data.notes) ...n.sources}) {
        File(p.join(dir.path, s))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('---\nid: r_${p.basenameWithoutExtension(s)}\ntitle: "세션 x 합성 대화"\n---\n');
      }
    });
    final total = Stopwatch()..start();
    late NeuralLayout big;
    await tester.runAsync(() async {
      big = await neuralLayoutInBackground(dir.path, p.join(dir.path, '_index.db'), rows, data.links);
    });
    final layoutMs = total.elapsedMilliseconds;
    neuralPaintCount = 0;
    await pump(tester, NeuralView(toggle: const SizedBox()), using: big);
    total.stop();
    final firstPaint = neuralLastPaintMicros / 1000;
    // 확대한 상태 그리기
    await tester.tap(find.text('+'));
    await tester.pump();
    final zoomPaint = neuralLastPaintMicros / 1000;
    // ignore: avoid_print
    print('[M8] 노트 1만 개: isolate(파일 읽기+배치) ${layoutMs}ms, 첫 표시까지 ${total.elapsedMilliseconds}ms, '
        '바탕 한 번 그리기 ${firstPaint.toStringAsFixed(1)}ms, 확대 뒤 ${zoomPaint.toStringAsFixed(1)}ms '
        '(flutter test 기록 시간 — 실제 GPU 그리기는 앱에서 따로)');
    expect(big.notes.length, 10000);
    expect(find.text('대화·문서 160 · 노트 10000 · 주제 13'), findsOneWidget);
    expect(total.elapsedMilliseconds, lessThan(3000), reason: '목표 1초의 3배를 넘으면 크게 느려진 것');
  });
}
