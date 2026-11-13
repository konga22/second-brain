import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
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

/// 시험에서 바꾸는 노트 목록 (null이면 기본 노트). 그물 배치를 다시 계산하는지 본다.
final _testNotes = NotifierProvider<_TestNotes, List<IndexedDoc>?>(_TestNotes.new);

class _TestNotes extends Notifier<List<IndexedDoc>?> {
  @override
  List<IndexedDoc>? build() => null;

  void set(List<IndexedDoc> notes) => state = notes;
}

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

  /// 시험 중에 바꾸는 배치. 바꾼 뒤 `container.invalidate(neuralLayoutProvider)`로 다시 읽힌다 (CLI·AI 저장으로 다시 계산되는 것과 같음).
  NeuralLayout? live;
  setUp(() {
    live = null;
    neuralPainterCacheLimit = 800;
  });

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    NeuralLayout? using,
    FutureOr<Map<String, Point<double>>> Function(Ref ref)? graph,
  }) async {
    tester.view.physicalSize = const Size(1000, 700) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        neuralLayoutProvider.overrideWith((ref) async => live ?? using ?? layout),
        notesProvider.overrideWith((ref) => ref.watch(_testNotes) ?? [for (final s in specs) doc(s)]),
        linksProvider.overrideWithValue(const [NoteLink(fromId: 'n_1', toId: 'n_3', kind: 'link')]),
        graphLayoutProvider.overrideWith(
          graph ?? (ref) async => {for (var i = 0; i < specs.length; i++) specs[i].id: Point(i * 80.0, (i % 2) * 60.0)},
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
  Offset inputIn(NeuralLayout l, int i) => Offset(200, 92 + (i + 0.5) * 560 / l.inputs.length);
  Offset topicIn(NeuralLayout l, int t) => Offset(830, 92 + (t + 0.5) * 560 / l.topics.length);
  Offset noteIn(NeuralLayout l, String id) => Offset(515, 92 + (l.indexOfNote(id)! + 0.5) * 560 / l.notes.length);

  Future<TestGesture> mouseAt(WidgetTester tester, Offset at) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(at);
    await tester.pumpAndSettle();
    return mouse;
  }

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

  testWidgets('이름표: 평소는 한 줄로 줄이고, 마우스 올림·고른 길은 자르지 않고 전체 (11/13 사용자 결정)', (tester) async {
    await pump(tester, NeuralView(toggle: const SizedBox()));
    // 확대하면 노트 이름표가 바탕에 나온다: 긴 제목은 한 줄로 줄인다 (말줄임)
    neuralLabelLog.clear();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('+'));
      await tester.pumpAndSettle(); // 확대는 0.25초 동안 부드럽게 (5.6): 단계마다 끝까지 그려 중간 배율의 이름표도 본다
    }
    await tester.pumpAndSettle();
    final plain = neuralLabelLog.where((l) => l.text == longTitle);
    expect(plain, isNotEmpty, reason: '확대하면 긴 제목 노트에도 이름표가 붙는다');
    expect(plain.last.lines, 1);
    expect(plain.last.cut, isTrue, reason: '평소 이름표는 한 줄로 줄인다');
    expect(neuralLabelLog.where((l) => l.text == '결제 웹훅 재시도').last.cut, isFalse, reason: '짧은 제목은 그대로');

    // 마우스를 올리면 이름 전체 (말줄임 없음)
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.tap(find.text('맞추기'));
    await tester.pumpAndSettle();
    neuralLabelLog.clear();
    await mouse.moveTo(noteAt('n_2'));
    await tester.pumpAndSettle();
    expect(find.text(longTitle), findsOneWidget, reason: '마우스 올림 안내에 제목 전체');
    final hovered = neuralLabelLog.where((l) => l.text == longTitle && l.strong);
    expect(hovered, isNotEmpty, reason: '노드 옆 이름표도 제목 전체');
    expect(hovered.last.lines, greaterThan(1), reason: '긴 제목은 줄을 바꾼다');
    expect(hovered.last.cut, isFalse);
    await mouse.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();

    // 고르면 고른 길의 노트 이름표도 전체
    neuralLabelLog.clear();
    await tester.tapAt(noteAt('n_2'));
    await tester.pumpAndSettle();
    final picked = neuralLabelLog.where((l) => l.text == longTitle && l.strong);
    expect(picked.where((l) => l.lines > 1 && !l.cut), isNotEmpty);
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

  // ── 11/13 검토 반영 (설계서_프롬프트이후 5.3) ──

  testWidgets('검토 1: 배치가 다시 계산돼 번호가 바뀌거나 없어져도, 고른 주제·마우스 올린 노드를 이름으로 다시 찾는다', (tester) async {
    await pump(tester, NeuralView(toggle: const SizedBox()));
    // 두 번째 주제를 고르고(패널은 그대로) 마지막 노트에 마우스를 올린다
    final picked = layout.topics[1].name;
    await tester.tapAt(topicAt(1));
    await tester.pumpAndSettle();
    final lastNote = layout.notes.last.id;
    await mouseAt(tester, noteAt(lastNote));
    expect(find.byKey(const ValueKey('neural-tooltip')), findsOneWidget);

    // 고른 주제만 남은 배치 (CLI가 다른 주제 노트를 지운 것처럼): 주제 1개, 노트 수도 줄어든다
    final only = [for (final s in specs) if (s.topic == picked) s];
    live = layoutNeural(only, const []);
    neuralLabelLog.clear();
    container.invalidate(neuralLayoutProvider);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '예전에는 topics[1]·notes[4]를 읽어 RangeError');
    expect({for (final l in neuralLabelLog) if (l.strong) l.text}, contains('$picked  ${only.length}'),
        reason: '고른 주제는 0번이 되어도 그대로 골라져 있다');

    // 번호가 바뀐 배치: 고른 주제가 0번, 새 주제 'Z'가 1번이 된다 → 이름으로 찾아 고른 주제를 밝혀야 한다
    live = layoutNeural([
      ...only,
      const NeuralNoteSpec(id: 'z1', title: '새 주제 노트', topic: 'Z', sources: ['raw/imports/2026-11-07-참고.md']),
    ], const []);
    expect(live!.indexOfTopic(picked), 0, reason: '시험 전제: 고른 주제가 0번');
    neuralLabelLog.clear();
    container.invalidate(neuralLayoutProvider);
    await tester.pumpAndSettle();
    final strong = {for (final l in neuralLabelLog) if (l.strong) l.text};
    expect(strong, contains('$picked  ${only.length}'));
    expect(strong, isNot(contains('Z  1')), reason: '번호로 기억하면 다른 주제가 밝아진다');

    // 고른 주제가 사라지면 고르기를 버린다 (막도 걷힌다)
    live = layoutNeural([
      const NeuralNoteSpec(id: 'z1', title: '새 주제 노트', topic: 'Z', sources: ['raw/sessions/2026-12-30-zzzz.md']),
    ], const []);
    container.invalidate(neuralLayoutProvider);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final veil = tester.widget<AnimatedOpacity>(find.descendant(of: find.byType(NeuralView), matching: find.byType(AnimatedOpacity)));
    expect(veil.opacity, 0);
  });

  /// 노트 1000개가 저마다 다른 대화에서 나왔고 모두 한 주제 (주제를 고르면 대화 1000개가 밝아진다).
  NeuralLayout manyInputs() => layoutNeural([
    for (var i = 0; i < 1000; i++)
      NeuralNoteSpec(
        id: 'm$i',
        title: '많은 노트 $i',
        topic: '큰 주제',
        sources: ['raw/sessions/2026-01-${(1 + i % 28).toString().padLeft(2, '0')}-s$i.md'],
      ),
    const NeuralNoteSpec(id: 'u1', title: '다른 노트', topic: '작은 주제'),
  ], const []);

  testWidgets('검토 2: 큰 주제를 고르고 대화에 마우스를 올려도, 버린 글자 배치를 그리지 않는다', (tester) async {
    final big = manyInputs();
    await pump(tester, NeuralView(toggle: const SizedBox()), using: big);
    await tester.tapAt(topicIn(big, big.indexOfTopic('큰 주제')!));
    await tester.pump(const Duration(milliseconds: 16));
    final mouse = await mouseAt(tester, inputIn(big, 0));
    for (var f = 0; f < 10; f++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull, reason: '예전에는 한 번 그리는 도중 캐시 800개를 넘으면 쥐고 있던 이름표까지 버렸다');
    // 캐시 한도를 아주 작게 해도 한 번의 그리기 안에서는 버리지 않는다
    neuralPainterCacheLimit = 1;
    await tester.tapAt(noteIn(big, 'm5'));
    await tester.pumpAndSettle();
    await mouse.moveTo(noteIn(big, 'm7'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('검토 3: 빛이 흐르는 동안 고른 길 그림은 다시 그리지 않고, 한 프레임의 선·빛 번짐 수에 상한이 있다', (tester) async {
    final big = manyInputs();
    await pump(tester, NeuralView(toggle: const SizedBox()), using: big);
    await tester.tapAt(topicIn(big, big.indexOfTopic('큰 주제')!));
    await tester.pump(const Duration(milliseconds: 16));
    neuralPathPaintCount = 0;
    neuralPulseFrames = 0;
    neuralPulseMaxLines = 0;
    neuralPulseMaxGlows = 0;
    neuralLabelLog.clear();
    for (var f = 0; f < 100; f++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(neuralPulseFrames, greaterThan(50), reason: '빛은 프레임마다 흐른다');
    expect(neuralPathPaintCount, 0, reason: '고른 길(선 2000개·이름표)은 고를 때 한 번만 그린다');
    expect(neuralLabelLog, isEmpty, reason: '빛 프레임에서 이름표를 다시 배치·그리지 않는다');
    expect(neuralPulseMaxLines, lessThanOrEqualTo(2 * 600));
    expect(neuralPulseMaxGlows, lessThanOrEqualTo(48 + 24));
  });

  testWidgets('검토 4: 노트를 고르면 그 출처·주제 이름표가 모두, 서로 겹치지 않게 보인다 (빽빽해도)', (tester) async {
    // 대화 60개(간격 약 9px)와 주제 50개(약 11px): 바탕 이름표가 나오지 않을 만큼 빽빽하다
    final own = ['raw/sessions/2026-01-01-one.md', 'raw/sessions/2026-01-02-two.md', 'raw/sessions/2026-01-03-three.md'];
    final dense = layoutNeural([
      NeuralNoteSpec(id: 'target', title: '고른 노트', topic: 'A', sources: own),
      for (var i = 0; i < 57; i++)
        NeuralNoteSpec(
          id: 'o$i',
          title: '다른 노트 $i',
          topic: 'T${i % 49}',
          sources: ['raw/sessions/2026-02-${(1 + i % 28).toString().padLeft(2, '0')}-o$i.md'],
        ),
    ], const [('target', 'o3'), ('target', 'o4')], inputTitles: {
      own[0]: '출처 하나',
      own[1]: '출처 둘',
      own[2]: '출처 셋',
    }, inputRawIds: {own[0]: 'r_one'});
    final ins = [for (final path in own) dense.indexOfInput(path)!]..sort();
    expect(ins.last - ins.first, 2, reason: '시험 전제: 세 출처가 바로 붙어 있다 (이름표가 겹칠 자리)');
    await pump(tester, NeuralView(toggle: const SizedBox()), using: dense);
    neuralLabelLog.clear();
    await tester.tapAt(noteIn(dense, 'target'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteProvider), 'target');
    final want = ['출처 하나', '출처 둘', '출처 셋', '고른 노트', 'A  1', 'T3  2', 'T4  2'];
    final rects = <String, Rect>{for (final l in neuralLabelLog) l.text: l.rect};
    expect(rects.keys, containsAll(want));
    for (var a = 0; a < want.length; a++) {
      for (var b = a + 1; b < want.length; b++) {
        expect(rects[want[a]]!.overlaps(rects[want[b]]!), isFalse, reason: '${want[a]} · ${want[b]} 이름표가 겹친다');
      }
    }
  });

  testWidgets('화면 검토: 고른 길 이름표에 반쯤 가리는 바탕 이름표는 빼서 조각이 남지 않는다', (tester) async {
    // 노트 30개(간격 약 19px)에 긴 제목: 고른 노트 이름표(여러 줄)가 이웃 이름표 자리를 덮는다
    final crowded = layoutNeural([
      for (var i = 0; i < 30; i++)
        NeuralNoteSpec(
          id: 'c$i',
          title: i == 15 ? longTitle : '이웃 노트 $i 이름표는 두 줄이 될 만큼 조금 길다',
          topic: 'T${i % 5}',
          sources: ['raw/sessions/2026-03-${(1 + i % 20).toString().padLeft(2, '0')}-c$i.md'],
        ),
    ], const []);
    await pump(tester, NeuralView(toggle: const SizedBox()), using: crowded);
    await tester.tap(find.text('+'));
    await tester.pumpAndSettle();
    neuralLabelLog.clear();
    container.read(selectedNoteProvider.notifier).select('c15');
    await tester.pumpAndSettle();
    final picked = neuralLabelLog.where((l) => l.text == longTitle && l.strong).toList();
    expect(picked, isNotEmpty);
    final box = picked.last.rect.inflate(3);
    final dimmed = neuralLabelLog.where((l) => !l.strong && l.text != longTitle);
    expect(dimmed, isNotEmpty, reason: '시험 전제: 바탕 이름표가 어둡게 보인다');
    for (final l in dimmed) {
      expect(l.rect.overlaps(box), isFalse, reason: '${l.text} 이름표가 고른 노트 이름표 밑에 조각으로 남는다');
    }
  });

  testWidgets('검토 4: 고른 길 이름표가 층 높이에 다 들어가지 않으면 그 자리에 목록으로 모두 보인다', (tester) async {
    const big = 'raw/sessions/2026-01-01-big.md';
    final wide = layoutNeural([
      for (var i = 0; i < 40; i++) NeuralNoteSpec(id: 'e$i', title: '큰 대화에서 나온 노트 $i', topic: 'E', sources: const [big]),
      const NeuralNoteSpec(id: 'f1', title: '다른 노트', topic: 'F', sources: ['raw/sessions/2026-01-02-small.md']),
    ], const [], inputTitles: const {big: '큰 대화'}, inputRawIds: const {big: 'r_big'});
    await pump(tester, NeuralView(toggle: const SizedBox()), using: wide);
    await tester.tapAt(inputIn(wide, wide.indexOfInput(big)!));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteProvider), 'r_big');
    final list = find.byKey(const ValueKey('neural-path-list-note'));
    expect(list, findsOneWidget);
    expect(find.descendant(of: list, matching: find.text('고른 길 · 노트 40')), findsOneWidget);
    final first = wide.notes[wide.inputs[wide.indexOfInput(big)!].notes.first].title;
    expect(find.descendant(of: list, matching: find.text(first)), findsOneWidget);
    // 목록은 보이는 영역 안에 있다 (L-0007)
    final box = tester.getRect(list);
    expect(box.top >= 0 && box.bottom <= 700 && box.left >= 0 && box.right <= 1000, isTrue, reason: '$box');
    await tester.drag(list, const Offset(0, -3000));
    await tester.pumpAndSettle();
    final last = wide.notes[wide.inputs[wide.indexOfInput(big)!].notes.last].title;
    expect(find.descendant(of: list, matching: find.text(last)), findsOneWidget);
  });

  testWidgets('검토 6: 그물 배치 중이어도 [신경망]으로 갈 수 있다', (tester) async {
    final never = Completer<Map<String, Point<double>>>();
    await pump(tester, const GraphView(), graph: (ref) => never.future);
    expect(find.text('그래프 배치 중…'), findsOneWidget);
    await tester.tap(find.text('신경망'));
    await tester.pumpAndSettle();
    expect(find.byType(NeuralView), findsOneWidget);
  });

  testWidgets('검토 6: 그물 배치가 실패해도 [신경망]으로 갈 수 있다', (tester) async {
    await pump(tester, const GraphView(), graph: (ref) => throw StateError('배치 실패'));
    expect(find.textContaining('그래프를 그리지 못했습니다'), findsOneWidget);
    await tester.tap(find.text('신경망'));
    await tester.pumpAndSettle();
    expect(find.byType(NeuralView), findsOneWidget);
  });

  testWidgets('검토 6: 신경망 보기 동안 노트가 바뀌어도 그물 배치를 다시 계산하지 않는다 (돌아오면 한 번)', (tester) async {
    var builds = 0;
    await pump(tester, const GraphView(), graph: (ref) async {
      final notes = ref.watch(notesProvider);
      builds++;
      return {for (var i = 0; i < notes.length; i++) notes[i].id: Point(i * 80.0, 0.0)};
    });
    expect(builds, 1);
    await tester.tap(find.text('신경망'));
    await tester.pumpAndSettle();
    container.read(_testNotes.notifier).set([for (final s in specs.take(3)) doc(s)]);
    await tester.pumpAndSettle();
    container.read(_testNotes.notifier).set([for (final s in specs.take(2)) doc(s)]);
    await tester.pumpAndSettle();
    expect(builds, 1, reason: '보이지 않는 그물 배치를 다시 하지 않는다');
    await tester.tap(find.text('그물'));
    await tester.pumpAndSettle();
    expect(builds, 2);
  });

  testWidgets('검토 7: 마우스 안내 상자는 같은 노드 위에서 움직여도 마우스를 따라간다', (tester) async {
    await pump(tester, NeuralView(toggle: const SizedBox()));
    final mouse = await mouseAt(tester, noteAt('n_2'));
    final tip = find.byKey(const ValueKey('neural-tooltip'));
    final before = tester.getTopLeft(tip);
    await mouse.moveTo(noteAt('n_2') + const Offset(0, 6));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(tip) - before, const Offset(0, 6));
  });

  test('검토 5: 지식 폴더 읽기가 제한 시간 안에 끝나지 않으면 "배치 중…"에 머물지 않고 오류로 끝난다', () async {
    final dir = Directory.systemTemp.createTempSync('neural_timeout_');
    addTearDown(() => dir.deleteSync(recursive: true));
    await expectLater(
      neuralLayoutInBackground(dir.path, p.join(dir.path, '_index.db'), [
        (id: 'n_1', path: 'wiki/a.md', title: '가', topic: '결제', isDraft: false),
      ], const [], timeout: Duration.zero),
      throwsA(isA<TimeoutException>()),
    );
  });

  // 시간을 재는 시험이라 따로 돌린다: `flutter test` 전체는 시험 파일을 함께 돌려 같은 일이 0.5초 → 14초까지 늘었다
  // (11/13). NEURAL_M8=1 flutter test test/neural_view_test.dart --plain-name M8
  testWidgets('M8: 노트 1만 개 첫 표시 시간 (파일 읽기·배치 isolate + 첫 그리기)', skip: Platform.environment['NEURAL_M8'] == null, (tester) async {
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
    await tester.pumpAndSettle(); // 확대는 0.25초 동안 부드럽게 바뀐다 (5.6): 끝난 뒤의 그림을 잰다
    final zoomPaint = neuralLastPaintMicros / 1000;
    // ignore: avoid_print
    print('[M8] 노트 1만 개: isolate(파일 읽기+배치) ${layoutMs}ms, 첫 표시까지 ${total.elapsedMilliseconds}ms, '
        '바탕 한 번 그리기 ${firstPaint.toStringAsFixed(1)}ms, 확대 뒤 ${zoomPaint.toStringAsFixed(1)}ms '
        '(flutter test 기록 시간 — 실제 GPU 그리기는 앱에서 따로)');
    expect(big.notes.length, 10000);
    expect(find.text('대화·문서 160 · 노트 10000 · 주제 13'), findsOneWidget);
    // 합격선: 목표 1초의 3배 (디버그·JIT 기준, 단독 실행). 목표와 견주는 숫자는 위 출력으로 본다.
    expect(total.elapsedMilliseconds, lessThan(3000), reason: '첫 표시가 크게 느려짐');
  });

  // 고른 길 한 프레임 시간 (5.3, 11/13 검토 3). 노트 1만 개에서 가장 큰 주제·대화를 고르고 빛이 흐르는
  // 1.6초 동안 프레임마다 빌드·배치·그리기(기록)에 든 시간을 잰다. 시간을 재는 시험이라 따로 돌린다:
  // NEURAL_FRAME=1 flutter test test/neural_view_test.dart --plain-name 프레임
  for (final (inputs, topics) in [(600, 13), (3000, 4)]) {
    testWidgets('프레임: 노트 1만·대화 $inputs·주제 $topics에서 큰 주제·대화를 고른 뒤 빛 흐름 한 프레임 시간',
        skip: Platform.environment['NEURAL_FRAME'] == null, (tester) async {
      final data = syntheticNeural(10000, inputs: inputs, topics: topics, seed: 5);
      final big = layoutNeural(data.notes, data.links);
      var t = 0;
      for (var i = 1; i < big.topics.length; i++) {
        if (big.topics[i].count > big.topics[t].count) t = i;
      }
      await pump(tester, NeuralView(toggle: const SizedBox()), using: big);
      // 프레임마다 CPU(빌드·배치·그림 기록)와 래스터(화면 전체를 그림으로 굽기, 바탕 포함)를 잰다.
      final raster = <String, List<int>>{};
      Future<List<int>> frames([String? name]) async {
        final out = <int>[];
        for (var f = 0; f < 100; f++) {
          final w = Stopwatch()..start();
          await tester.pump(const Duration(milliseconds: 16));
          out.add(w.elapsedMicroseconds);
          if (name != null && f % 10 == 5) {
            final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
            await tester.runAsync(() async {
              final r = Stopwatch()..start();
              final image = await layer.toImage(const Rect.fromLTWH(0, 0, 1000, 700));
              (raster[name] ??= []).add(r.elapsedMicroseconds);
              image.dispose();
            });
          }
        }
        return out;
      }

      await frames('고르기 전');

      String stat(List<int> xs) {
        final sorted = [...xs]..sort();
        final mean = xs.reduce((a, b) => a + b) / xs.length / 1000;
        return '평균 ${mean.toStringAsFixed(2)}ms, 중앙 ${(sorted[sorted.length ~/ 2] / 1000).toStringAsFixed(2)}ms, '
            '최대 ${(sorted.last / 1000).toStringAsFixed(2)}ms';
      }

      await tester.tapAt(Offset(830, 92 + (t + 0.5) * 560 / big.topics.length));
      final topicFrames = await frames('주제');
      final lit = {for (var i = big.topics[t].start; i < big.topics[t].start + big.topics[t].count; i++) ...big.notes[i].inputs};
      var x = 0;
      for (var i = 1; i < big.inputs.length; i++) {
        if (big.inputs[i].notes.length > big.inputs[x].notes.length) x = i;
      }
      await tester.tapAt(Offset(200, 92 + (x + 0.5) * 560 / big.inputs.length));
      final inputFrames = await frames('대화');
      // ignore: avoid_print
      print('[프레임] 노트 1만·대화 $inputs·주제 $topics — 주제(노트 ${big.topics[t].count}, 대화 ${lit.length}) 고름: '
          '${stat(topicFrames)} / 대화(노트 ${big.inputs[x].notes.length}) 고름: ${stat(inputFrames)} (flutter test 디버그, 기록까지)');
      // ignore: avoid_print
      print('[래스터] ${[for (final e in raster.entries) '${e.key} ${stat(e.value)}'].join(' / ')}');
      expect(tester.takeException(), isNull);
    });
  }
}
