import 'dart:io';
import 'dart:math';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:secondbrain/app/theme/app_theme.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:secondbrain/features/home/graph_motion.dart';
import 'package:secondbrain/features/home/graph_view.dart';
import 'package:secondbrain/features/home/neural_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 그래프 움직임 (설계서_프롬프트이후 5.6): 부드러운 확대·축소, 노드 끌기, [원래대로].
void main() {
  IndexedDoc doc(String id, String topic) => IndexedDoc(
    id: id,
    path: 'wiki/$topic/$id.md',
    kind: 'note',
    title: '노트 $id',
    summary: '',
    tags: '',
    status: NoteStatus.active,
    mtime: DateTime(2026, 11, 13),
    hash: 'h',
  );

  // 그물: a─b─c─d 한 줄 + 연결 없는 z. a를 끌면 b(1단계)·c(2단계)만 따라오고 d(3단계)·z는 그대로여야 한다.
  final notes = [doc('a', '결제'), doc('b', '결제'), doc('c', '결제'), doc('d', '결제'), doc('z', '배포')];
  const links = [
    NoteLink(fromId: 'a', toId: 'b', kind: 'link'),
    NoteLink(fromId: 'b', toId: 'c', kind: 'link'),
    NoteLink(fromId: 'c', toId: 'd', kind: 'link'),
  ];
  const layout = {
    'a': Point(0.0, 0.0),
    'b': Point(90.0, 0.0),
    'c': Point(180.0, 0.0),
    'd': Point(270.0, 0.0),
    'z': Point(180.0, 220.0),
  };

  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, Widget child, {
    NeuralLayout? neural,
    List extra = const [],
    bool ownGraph = false,
    List<IndexedDoc>? withNotes,
    List<NoteLink>? withLinks,
    Map<String, Point<double>>? withLayout,
  }) async {
    tester.view.physicalSize = const Size(1000, 700) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        notesProvider.overrideWithValue(withNotes ?? notes),
        linksProvider.overrideWithValue(withLinks ?? links),
        if (!ownGraph) graphLayoutProvider.overrideWith((ref) async => withLayout ?? layout),
        if (neural != null) neuralLayoutProvider.overrideWith((ref) async => neural),
        ...extra.cast(),
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

  TransformationController controller(WidgetTester tester) =>
      tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!;
  double scale(WidgetTester tester) => controller(tester).value.getMaxScaleOnAxis();

  /// 그래프 좌표 → 화면 좌표. 그림 원점(노드 범위 왼쪽 위 - 여백 80·60 - 끌기 여유)은 배율에 따라 바뀌어 그때그때 읽는다.
  Offset screenAt(WidgetTester tester, Point<double> world) {
    final viewer = tester.getRect(find.byType(InteractiveViewer));
    return viewer.topLeft +
        MatrixUtils.transformPoint(controller(tester).value, Offset(world.x, world.y) - graphContentForTest.origin);
  }

  /// [frames]개 프레임(16ms)을 넘기며 배율을 모은다.
  Future<List<double>> frames(WidgetTester tester, double Function() read, {int frames = 25}) async {
    final out = <double>[];
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      out.add(read());
    }
    return out;
  }

  group('그물 보기 부드러운 확대', () {
    testWidgets('[+]는 0.25초 동안 중간 배율을 거쳐 1.25배에 닿는다', (tester) async {
      await pump(tester, const GraphView());
      final s0 = scale(tester);
      await tester.tap(find.text('+'));
      await tester.pump();
      expect(scale(tester), closeTo(s0, s0 * 0.01), reason: '누른 프레임에 바로 끝 배율로 튀면 안 된다');
      final seen = await frames(tester, () => scale(tester));
      final middle = seen.where((s) => s > s0 * 1.01 && s < s0 * 1.24);
      expect(middle.length, greaterThanOrEqualTo(5), reason: '중간 배율 프레임: $seen');
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1] - 1e-9), reason: '확대 중에 줄어들면 안 된다');
      }
      await tester.pumpAndSettle();
      expect(scale(tester), closeTo(s0 * 1.25, s0 * 0.001));
      // z축도 같은 배율 (v1.3.39, _fit 설명)
      final m = controller(tester).value;
      expect(m.entry(2, 2), closeTo(m.entry(0, 0), 1e-9));
    });

    testWidgets('빠르게 여러 번 누르면 이어서 간다: 튀지 않고 1.25³배에 닿는다', (tester) async {
      await pump(tester, const GraphView());
      final s0 = scale(tester);
      final seen = <double>[];
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('+'));
        seen.addAll(await frames(tester, () => scale(tester), frames: 4)); // 64ms 뒤 다시 누름 (애니메이션 도중)
      }
      seen.addAll(await frames(tester, () => scale(tester), frames: 25));
      expect(seen.last, closeTo(s0 * pow(1.25, 3), s0 * 0.002));
      var biggest = 0.0;
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1] - 1e-9), reason: '되돌아가지 않는다: $seen');
        biggest = max(biggest, seen[i] / seen[i - 1]);
      }
      // 한 프레임에 전체(약 1.95배)의 큰 부분을 한 번에 건너뛰지 않는다
      expect(biggest, lessThan(1.2), reason: '프레임 사이 가장 큰 배율 변화 $biggest');
    });

    testWidgets('[−]·[맞추기]도 부드럽게, 맞추기 끝은 처음 맞춘 배율과 같다', (tester) async {
      await pump(tester, const GraphView());
      final fitted = controller(tester).value.clone();
      await tester.tap(find.text('−'));
      await tester.pumpAndSettle();
      expect(scale(tester), closeTo(fitted.getMaxScaleOnAxis() * 0.8, 1e-6));
      await tester.tap(find.text('맞추기'));
      await tester.pump();
      final seen = await frames(tester, () => scale(tester), frames: 8);
      expect(seen.where((s) => s > fitted.getMaxScaleOnAxis() * 0.81 && s < fitted.getMaxScaleOnAxis() * 0.99), isNotEmpty);
      await tester.pumpAndSettle();
      for (var i = 0; i < 16; i++) {
        expect(controller(tester).value.storage[i], closeTo(fitted.storage[i], 1e-6));
      }
    });

    testWidgets('휠: 마우스 자리를 기준으로 부드럽게, 연달아 굴리면 이어서 (튀지 않음)', (tester) async {
      await pump(tester, const GraphView());
      final s0 = scale(tester);
      final viewer = tester.getRect(find.byType(InteractiveViewer));
      final at = viewer.topLeft + const Offset(400, 300);
      final sceneBefore = controller(tester).toScene(at - viewer.topLeft);

      await tester.sendEventToBinding(PointerScrollEvent(position: at, scrollDelta: const Offset(0, -40)));
      await tester.pump();
      expect(scale(tester), closeTo(s0, s0 * 0.01), reason: '휠 한 칸에 바로 튀지 않는다');
      final seen = await frames(tester, () => scale(tester), frames: 4);
      // 도중에 두 칸 더
      await tester.sendEventToBinding(PointerScrollEvent(position: at, scrollDelta: const Offset(0, -40)));
      seen.addAll(await frames(tester, () => scale(tester), frames: 2));
      await tester.sendEventToBinding(PointerScrollEvent(position: at, scrollDelta: const Offset(0, -40)));
      seen.addAll(await frames(tester, () => scale(tester), frames: 25));
      expect(seen.last, closeTo(s0 * exp(3 * 40 / 200), s0 * 0.002), reason: 'InteractiveViewer와 같은 배율 셈');
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1] - 1e-9), reason: '$seen');
      }
      expect(seen.where((s) => s > s0 * 1.01 && s < seen.last * 0.99).length, greaterThanOrEqualTo(5));
      // 마우스 아래의 그림 자리는 그대로 (마우스 자리 기준 확대)
      final sceneAfter = controller(tester).toScene(at - viewer.topLeft);
      expect((sceneAfter - sceneBefore).distance, lessThan(0.01));
    });

    testWidgets('움직임 줄이기 설정이면 바로 바뀐다', (tester) async {
      await pump(tester, const MediaQuery(data: MediaQueryData(disableAnimations: true), child: GraphView()));
      final s0 = scale(tester);
      await tester.tap(find.text('+'));
      await tester.pump();
      expect(scale(tester), closeTo(s0 * 1.25, s0 * 0.001));
    });
  });

  group('신경망 보기 부드러운 확대', () {
    final neural = layoutNeural([
      for (var i = 0; i < 40; i++)
        NeuralNoteSpec(id: 'n$i', title: '노트 $i', topic: 'T${i % 4}', sources: ['raw/sessions/2026-11-01-s${i % 6}.md']),
    ], const []);

    testWidgets('[+]·휠은 중간 배율을 거치고, 연달아 누르면 이어서 간다', (tester) async {
      await pump(tester, NeuralView(toggle: const SizedBox()), neural: neural);
      expect(neuralZoom, 1);
      final seen = <double>[];
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text('+'));
        seen.addAll(await frames(tester, () => neuralZoom, frames: 4));
      }
      seen.addAll(await frames(tester, () => neuralZoom, frames: 25));
      expect(seen.last, closeTo(1.5625, 1e-6));
      expect(seen.where((k) => k > 1.01 && k < 1.55).length, greaterThanOrEqualTo(5), reason: '$seen');
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1] - 1e-9));
      }

      // 휠: 바로 튀지 않는다
      final view = tester.getRect(find.byType(NeuralView));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: view.center, scrollDelta: const Offset(0, -60), kind: PointerDeviceKind.mouse),
      );
      await tester.pump();
      expect(neuralZoom, closeTo(1.5625, 1e-6));
      await tester.pump(const Duration(milliseconds: 100));
      expect(neuralZoom, greaterThan(1.57));
      expect(neuralZoom, lessThan(1.5625 * exp(60 / 300) - 0.01));
      await tester.pumpAndSettle();
      expect(neuralZoom, closeTo(1.5625 * exp(60 / 300), 1e-6));

      // [맞추기]: 부드럽게 1배로
      await tester.tap(find.text('맞추기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(neuralZoom, inExclusiveRange(1.0, 1.5625 * exp(60 / 300)));
      await tester.pumpAndSettle();
      expect(neuralZoom, 1);
    });
  });

  group('노드 끌기·[원래대로]', () {
    GraphMotion motion() => graphMotionForTest!;

    /// 그래프 좌표 → 화면 좌표 (그림 원점은 노드 범위 왼쪽 위 - 여백 80·60 - 끌기 여유).
    Offset screenOf(WidgetTester tester, Point<double> world) => screenAt(tester, world);

    Point<double> now(String id) => motion().moved[id] ?? layout[id]!;
    double moved(String id) => (Offset(now(id).x, now(id).y) - Offset(layout[id]!.x, layout[id]!.y)).distance;

    Future<void> drag(WidgetTester tester, String id, Offset by, {int steps = 20}) async {
      final g = await tester.startGesture(screenOf(tester, layout[id]!), kind: PointerDeviceKind.mouse);
      for (var i = 0; i < steps; i++) {
        await g.moveBy(by / steps.toDouble());
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
    }

    testWidgets('노드를 끌면 그 노드가 옮겨지고 이웃이 따라온다. 멀리 있는 노드·화면 이동은 그대로', (tester) async {
      await pump(tester, const GraphView());
      final view = controller(tester).value.clone();
      final scale = view.getMaxScaleOnAxis();
      final g = await tester.startGesture(screenOf(tester, layout['a']!), kind: PointerDeviceKind.mouse);
      // 끄는 도중 (아래로 100px)
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(now('a').y, closeTo(100 / scale, 0.5), reason: '끈 노드는 손을 따라온다');
      expect(moved('b'), greaterThan(1), reason: '바로 이웃은 고무줄처럼 따라온다');
      await g.up();
      final dropped = now('a');
      await tester.pumpAndSettle();
      expect(now('a'), dropped, reason: '놓은 노드는 그 자리에 머문다');
      expect(moved('b'), greaterThan(5));
      expect(motion().moved.containsKey('z'), isFalse, reason: '연결 없는 먼 노드는 움직이지 않는다');
      expect(motion().moved.containsKey('d'), isFalse, reason: '3단계 노드는 움직이지 않는다 (끈 노드 주변만)');
      expect(motion().live, isNot(contains('z')));
      expect(motion().live, unorderedEquals(['a', 'b', 'c']));
      // 이웃은 연결 길이를 대체로 지킨다 (쉬는 길이 90)
      final ab = Offset(now('a').x - now('b').x, now('a').y - now('b').y).distance;
      expect(ab, closeTo(90, 20));
      for (var i = 0; i < 16; i++) {
        expect(controller(tester).value.storage[i], view.storage[i], reason: '노드를 끌면 화면은 옮겨지지 않는다');
      }
      expect(container.read(selectedNoteProvider), isNull, reason: '끌기는 고르기가 아니다');
    });

    testWidgets('움직이지 않고 누르면 지금처럼 고른다. 빈 곳을 끌면 화면이 옮겨진다', (tester) async {
      await pump(tester, const GraphView());
      await tester.tapAt(screenOf(tester, layout['b']!));
      await tester.pumpAndSettle();
      expect(container.read(selectedNoteProvider), 'b');
      expect(motion().hasMoved, isFalse);

      final before = controller(tester).value.getTranslation();
      final empty = screenOf(tester, const Point(60, 150)); // 노드 없는 곳
      final g = await tester.startGesture(empty, kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(8, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(controller(tester).value.getTranslation().x, greaterThan(before.x + 40), reason: '빈 곳 끌기 = 화면 이동');
      expect(motion().hasMoved, isFalse);
    });

    testWidgets('[원래대로]: 옮긴 것이 있을 때만 켜지고, 0.4초 동안 돌아가 저장된 배치와 같아진다. 저장된 배치는 그대로', (tester) async {
      final temp = Directory.systemTemp.createTempSync('graph_motion_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final vault = Vault(p.join(temp.path, 'vault'))..ensure();
      final dbPath = p.join(temp.path, 'index.db');
      final index = SearchIndex.open(vault, path: dbPath);
      addTearDown(index.close);
      index.saveGraphPositions(layout);
      final savedBefore = index.graphPositions();
      final bytesBefore = File(dbPath).readAsBytesSync();
      await pump(
        tester,
        const GraphView(),
        extra: [
          searchIndexProvider.overrideWithValue(index),
          graphLayoutProvider.overrideWith((ref) async => ref.watch(searchIndexProvider).graphPositions()),
        ],
        ownGraph: true,
      );
      final graphMap = container.read(graphLayoutProvider).value!;

      // 옮긴 것이 없으면 꺼져 있다 (눌러도 아무 일 없음)
      await tester.tap(find.text('원래대로'));
      await tester.pumpAndSettle();
      expect(motion().hasMoved, isFalse);

      await drag(tester, 'a', const Offset(0, 120));
      await drag(tester, 'c', const Offset(-60, -90));
      await tester.pumpAndSettle();
      expect(moved('a'), greaterThan(30));
      expect(moved('c'), greaterThan(20));
      final away = {for (final id in ['a', 'b', 'c']) id: moved(id)};

      await tester.tap(find.text('원래대로'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // 중간: 돌아가는 중 (원래 자리와 옮긴 자리 사이)
      expect(moved('a'), inExclusiveRange(0.5, away['a']!));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(motion().hasMoved, isFalse);
      expect(motion().moved, isEmpty);
      for (final id in layout.keys) {
        expect(now(id), graphMap[id], reason: '$id 노드가 저장된 배치 자리로');
      }
      // 끌어서 바꾼 자리는 저장하지 않는다: graph_pos·색인 파일 그대로
      expect(index.graphPositions(), savedBefore);
      expect(File(dbPath).readAsBytesSync(), bytesBefore);
    });

    testWidgets('움직임 줄이기: 끈 노드만 움직이고, [원래대로]는 바로', (tester) async {
      await pump(tester, const MediaQuery(data: MediaQueryData(disableAnimations: true), child: GraphView()));
      await drag(tester, 'a', const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(moved('a'), greaterThan(30));
      expect(moved('b'), 0);
      await tester.tap(find.text('원래대로'));
      await tester.pump();
      expect(motion().moved, isEmpty);
    });
  });

  // 11/14 실제 앱에서 발견 (설계서_프롬프트이후 5.6): 노트 1만 개·주제 40개에서 노드를 끈 캡처에 연결선이 그래프 위로
  // 솟아 주제 칩 뒤로 들어갔다. 끌기 좌표는 맞았다(끈 노드가 손 밑 0.00px). 맨 위 노드가 칩 뒤에 놓인 것이 원인:
  // [맞추기]가 위 도구 줄 높이를 칩 두 줄(84px)로 못박아, 주제가 많아 칩이 다섯 줄이 되면 그래프 윗부분이 칩 뒤로 갔다.
  testWidgets('주제 칩이 여러 줄이어도 [맞추기]는 맨 위 노드를 칩 아래에 둔다 (11/14 실제 앱에서 발견)', (tester) async {
    final manyNotes = [for (var i = 0; i < 40; i++) doc('t$i', '주제${i.toString().padLeft(2, '0')}')];
    final manyLayout = {
      // 세로로 긴 배치: 높이에 맞춰지므로 위 여백이 곧 도구 줄 자리다 (실제 앱 1만 개도 높이에 맞춰졌다)
      for (var i = 0; i < 40; i++) 't$i': Point((i % 4) * 90.0, (i ~/ 4) * 160.0),
    };
    await pump(tester, const GraphView(), withNotes: manyNotes, withLinks: const [], withLayout: manyLayout);
    final chips = find.ancestor(of: find.text('주제39'), matching: find.byType(Wrap));
    final chipsBottom = tester.getRect(chips).bottom;
    expect(chipsBottom - tester.getRect(find.byType(InteractiveViewer)).top, greaterThan(120), reason: '칩이 세 줄 넘게 감겨야 시험이 된다');
    final top = manyLayout.values.reduce((a, b) => a.y <= b.y ? a : b);
    expect(screenAt(tester, top).dy, greaterThan(chipsBottom), reason: '맨 위 노드가 주제 칩 뒤에 가리면 안 된다');
    // [맞추기] 버튼도 같은 자리
    await tester.tap(find.text('맞추기'));
    await tester.pumpAndSettle();
    expect(screenAt(tester, top).dy, greaterThan(chipsBottom));
  });

  // 11/14 실제 앱 (설계서_프롬프트이후 5.6): 노트 1만 개를 [맞추기]하면 배율이 약 0.14라, 끌기 여유 200(그래프 좌표)이
  // 화면에서 28px뿐이었다. 무리 가장자리 노드를 바깥으로 끌면 곧바로 멈췄다. 여유를 화면 기준(약 120px)으로 둔다.
  group('크게 줄여 볼 때 끌기 여유', () {
    // 세로로 긴 배치: [맞추기] 배율이 약 0.11이고 좌우에 빈 곳이 있다.
    final tallNotes = [for (var i = 0; i < 30; i++) doc('w$i', '주제${i % 3}')];
    final tallLayout = {for (var i = 0; i < 30; i++) 'w$i': Point((i % 5) * 750.0, (i ~/ 5) * 1000.0)};

    Offset worldAt(WidgetTester tester, Offset screen) {
      final viewer = tester.getRect(find.byType(InteractiveViewer));
      final local = MatrixUtils.transformPoint(Matrix4.inverted(controller(tester).value), screen - viewer.topLeft);
      return local + graphContentForTest.origin;
    }

    testWidgets('가장자리 노드를 화면에서 100px 바깥으로 끌 수 있고, 거기서 다시 잡힌다', (tester) async {
      await pump(tester, const GraphView(), withNotes: tallNotes, withLinks: const [], withLayout: tallLayout);
      final s = scale(tester);
      expect(s, lessThan(0.15), reason: '크게 줄여 보는 조건 (배율 $s)');
      expect(graphContentForTest.room * s, closeTo(graphDragRoomPixels, 1), reason: '여유는 화면에서 약 ${graphDragRoomPixels}px');
      // 오른쪽 가운데 노드를 오른쪽으로 100px
      const id = 'w14';
      final start = screenAt(tester, tallLayout[id]!);
      var g = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      final out = screenAt(tester, graphMotionForTest!.moved[id]!);
      expect(out.dx - start.dx, closeTo(100, 1), reason: '노드 범위 밖 100px까지 손을 따라간다 (예전: 약 30px에서 멈춤)');
      // 바깥에 둔 노드를 다시 잡아 안으로 50px
      g = await tester.startGesture(out, kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 5; i++) {
        await g.moveBy(const Offset(-10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(screenAt(tester, graphMotionForTest!.moved[id]!).dx, closeTo(out.dx - 50, 1), reason: '그림 영역 안이라 다시 잡힌다');
    });

    testWidgets('맞추기는 그대로: 노드 범위가 가운데에 오고, 여유가 바뀌어도 화면이 튀지 않는다', (tester) async {
      await pump(tester, const GraphView(), withNotes: tallNotes, withLinks: const [], withLayout: tallLayout);
      final viewer = tester.getRect(find.byType(InteractiveViewer));
      // 노드 범위(여백 80 포함) 좌우가 영역 가운데에 놓인다 (세로에 맞춰져 좌우가 남는다)
      final left = screenAt(tester, const Point(-80, 0)).dx, right = screenAt(tester, const Point(3000 + 80, 0)).dx;
      expect(left - viewer.left, closeTo(viewer.right - right, 1));
      // [−]: 가운데를 기준으로 줄인다. 줄이는 동안 여유(그림 원점)가 바뀌어도 가운데 점은 그 자리에 있어야 한다.
      final roomBefore = graphContentForTest.room;
      final center = worldAt(tester, viewer.center);
      await tester.tap(find.text('−'));
      await tester.pumpAndSettle();
      expect(graphContentForTest.room, greaterThan(roomBefore + 50), reason: '줄이면 여유(그래프 좌표)가 커진다');
      final after = screenAt(tester, Point(center.dx, center.dy));
      expect(after.dx, closeTo(viewer.center.dx, 0.5));
      expect(after.dy, closeTo(viewer.center.dy, 0.5));
      // [맞추기]로 돌아오면 처음과 같은 자리
      await tester.tap(find.text('맞추기'));
      await tester.pumpAndSettle();
      expect(screenAt(tester, const Point(-80, 0)).dx, closeTo(left, 0.5));
    });

    test('여유: 화면 약 120px, 그래프 좌표로 200~1,500', () {
      expect(graphDragRoomFor(1), graphDragRoom, reason: '보통 배율에서는 예전과 같다');
      expect(graphDragRoomFor(0.14), closeTo(graphDragRoomPixels / 0.14, 1e-9));
      expect(graphDragRoomFor(0.01), graphDragRoomMax);
    });
  });

  // 끝난 기준 (5.6): 노트 1만 개에서 끌기 중 한 프레임 시간. 시간을 재는 시험이라 따로 돌린다:
  // GRAPH_DRAG_FRAME=1 flutter test test/graph_motion_test.dart --plain-name 프레임
  // flutter test(디버그·JIT)의 빌드·배치·그리기 기록 시간이다. 실제 GPU 그리기(래스터)는 앱에서 따로 잰다.
  testWidgets('프레임: 노트 1만 개에서 노드 끌기 한 프레임 시간', skip: Platform.environment['GRAPH_DRAG_FRAME'] == null, (tester) async {
    final rnd = Random(7);
    const topics = 13;
    final bigNotes = <IndexedDoc>[];
    final bigLayout = <String, Point<double>>{};
    final bigLinks = <NoteLink>[];
    for (var i = 0; i < 10000; i++) {
      final t = i % topics;
      bigNotes.add(doc('n$i', '주제$t'));
      final center = t * 2 * pi / topics;
      final r = sqrt(rnd.nextDouble()) * 900, a = rnd.nextDouble() * 2 * pi;
      bigLayout['n$i'] = Point(cos(center) * 2600 + cos(a) * r, sin(center) * 2600 + sin(a) * r);
    }
    // 같은 주제의 가까운 번호끼리 1~2개 + 주제마다 허브(n0~n12)에 약 1.5%
    for (var i = topics; i < 10000; i++) {
      for (var j = 0, k = 1 + rnd.nextInt(2); j < k; j++) {
        final other = i - topics * (1 + rnd.nextInt(20));
        if (other >= 0) bigLinks.add(NoteLink(fromId: 'n$i', toId: 'n$other', kind: 'link'));
      }
      if (rnd.nextDouble() < 0.015) bigLinks.add(NoteLink(fromId: 'n$i', toId: 'n${i % topics}', kind: 'link'));
    }
    await pump(tester, const GraphView(), withNotes: bigNotes, withLinks: bigLinks, withLayout: bigLayout);
    final viewer = tester.getRect(find.byType(InteractiveViewer));

    Future<String> measure(String name, String id, {required int zoomSteps}) async {
      await tester.tap(find.text('맞추기'));
      await tester.pumpAndSettle();
      for (var i = 0; i < zoomSteps; i++) {
        await tester.tap(find.text('+'));
        await tester.pumpAndSettle();
      }
      // 노드를 화면 가운데로 옮겨 놓고 잡는다 (확대해도 화면 안에 있게)
      final m = controller(tester).value;
      final p = bigLayout[id]!;
      final local = Offset(p.x, p.y) - graphContentForTest.origin;
      final shift = viewer.center - (viewer.topLeft + MatrixUtils.transformPoint(m, local));
      controller(tester).value = Matrix4.identity()
        ..translateByDouble(shift.dx, shift.dy, 0, 1)
        ..multiply(m);
      await tester.pumpAndSettle();
      // 견줄 값: 노드에 마우스를 올린 프레임 (지금도 노드마다 그물 전체를 다시 빌드한다, 바탕은 다시 그리지 않음)
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: viewer.center + const Offset(0, 200));
      await tester.pumpAndSettle();
      final hoverWatch = Stopwatch()..start();
      await mouse.moveTo(viewer.center);
      await tester.pump(const Duration(milliseconds: 16));
      final hoverMs = hoverWatch.elapsedMicroseconds / 1000;
      await mouse.removePointer();
      await tester.pumpAndSettle();
      final paintsBefore = graphPaintCount;
      final g = await tester.startGesture(viewer.center, kind: PointerDeviceKind.mouse);
      final frames = <double>[];
      for (var i = 0; i < 90; i++) {
        final sw = Stopwatch()..start();
        await g.moveBy(Offset(4, i.isEven ? 2 : 1));
        await tester.pump(const Duration(milliseconds: 16));
        frames.add(sw.elapsedMicroseconds / 1000);
      }
      final release = <double>[];
      await g.up();
      await g.removePointer();
      for (var i = 0; i < 60; i++) {
        final sw = Stopwatch()..start();
        await tester.pump(const Duration(milliseconds: 16));
        release.add(sw.elapsedMicroseconds / 1000);
      }
      await tester.pumpAndSettle();
      final dragged = graphMotionForTest!.dragging ?? graphMotionForTest!.live.length;
      final first = frames.first;
      final rest = frames.skip(3).toList()..sort();
      final settle = release.toList()..sort();
      double at(List<double> v, double q) => v[(v.length * q).floor().clamp(0, v.length - 1)];
      final line =
          '[5.6 끌기] $name: 함께 움직인 노드 $dragged개, 첫 프레임(바탕 다시 그림 포함) ${first.toStringAsFixed(1)}ms, '
          '끄는 중 가운데 ${at(rest, 0.5).toStringAsFixed(1)}ms·p90 ${at(rest, 0.9).toStringAsFixed(1)}ms·최대 ${rest.last.toStringAsFixed(1)}ms, '
          '놓은 뒤 자리 잡기 가운데 ${at(settle, 0.5).toStringAsFixed(1)}ms·최대 ${settle.last.toStringAsFixed(1)}ms, '
          '마우스 올림 한 프레임 ${hoverMs.toStringAsFixed(1)}ms, 바탕 다시 그림 ${graphPaintCount - paintsBefore}번 (배율 ${controller(tester).value.getMaxScaleOnAxis().toStringAsFixed(2)})';
      // ignore: avoid_print
      print(line);
      expect(graphPaintCount - paintsBefore, lessThanOrEqualTo(2), reason: '끄는 동안 바탕(1만 개)을 다시 그리면 안 된다');
      // [원래대로] 한 번 (다음 측정을 깨끗하게)
      await tester.tap(find.text('원래대로'));
      await tester.pumpAndSettle();
      return line;
    }

    // 보통 노드 (연결 2~4개)와 허브(연결 약 150개 — 주변 상한 80개)
    final degree = <String, int>{};
    for (final l in bigLinks) {
      degree.update(l.fromId, (n) => n + 1, ifAbsent: () => 1);
      degree.update(l.toId, (n) => n + 1, ifAbsent: () => 1);
    }
    final plain = degree.entries.firstWhere((e) => e.value == 3 && int.parse(e.key.substring(1)) > 5000).key;
    await measure('보통 노드(연결 3) 맞춘 배율', plain, zoomSteps: 0);
    await measure('보통 노드(연결 3) 확대 ×1.25⁸', plain, zoomSteps: 8);
    await measure('허브(연결 ${degree['n3']}) 확대 ×1.25⁸', 'n3', zoomSteps: 8);
  });
}
