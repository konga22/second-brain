import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:secondbrain/features/home/graph_view.dart';
import 'package:secondbrain/features/home/neural_view.dart';

/// 실제 앱(맥 창)에서 프롬프트 이후 그래프 기능의 프레임 시간을 잰다 (설계서_프롬프트이후 5.3 M8, 5.6).
/// 위젯 시험(test/)은 GPU 그리기가 없어, 실제 그리기(raster)를 포함한 숫자는 여기서 본다.
///
/// 1. [신경망]을 누른 뒤 노드가 그려진 첫 프레임까지 (M8 목표 1초)
/// 2. 그물 보기 노드 끌기: 첫 프레임, 끄는 중 프레임(목표 약 16ms), [원래대로] 0.4초 동안의 프레임
/// 3. [+] 부드러운 확대 0.25초 동안의 프레임
/// 각 3번 재고 가운데 값을 적는다.
///
/// 노트 1만 개 합성 폴더 사본으로만 돈다 (실제 지식 폴더·설정 보호):
/// BRAIN_VAULT=<사본> BRAIN_CONFIG=<임시 파일> flutter drive --profile \
///   --driver=test_driver/integration_test.dart --target=integration_test/post_prompt_perf_test.dart -d macos \
///   [--dart-define=SHOT_DIR=<캡처 폴더>] [--dart-define=PERF_OUT=<결과 파일>]
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const shotDir = String.fromEnvironment('SHOT_DIR');
  const outPath = String.fromEnvironment('PERF_OUT');
  final lines = <String>[];

  void report(String line) {
    debugPrint('[PERF] $line');
    lines.add(line);
    if (outPath.isNotEmpty) File(outPath).writeAsStringSync('${lines.join('\n')}\n');
  }

  Future<void> settle(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (shotDir.isEmpty) return;
    final view = tester.binding.renderViews.first;
    // profile 모드에서는 debugLayer가 비어 있어 layer를 쓴다.
    // ignore: invalid_use_of_protected_member
    final layer = view.layer! as OffsetLayer;
    // 바탕 층 좌표는 물리 픽셀이다 (논리 크기 × 화면 배율).
    final image = await layer.toImage(Offset.zero & (view.size * tester.view.devicePixelRatio), pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$shotDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  double ms(Duration d) => d.inMicroseconds / 1000;
  double at(List<double> sorted, double q) =>
      sorted.isEmpty ? 0 : sorted[(sorted.length * q).floor().clamp(0, sorted.length - 1)];
  double median(List<double> v) => at(v.toList()..sort(), 0.5);
  String f(double v) => v.toStringAsFixed(1);

  /// 프레임 기록: 빌드(화면 스레드: build·layout·paint)와 그리기(raster 스레드).
  String frameStats(List<ui.FrameTiming> t) {
    final build = t.map((x) => ms(x.buildDuration)).toList()..sort();
    final raster = t.map((x) => ms(x.rasterDuration)).toList()..sort();
    final work = t.map((x) => ms(x.buildDuration) + ms(x.rasterDuration)).toList()..sort();
    final over = t.where((x) => ms(x.buildDuration) > 16.7 || ms(x.rasterDuration) > 16.7).length;
    return '프레임 ${t.length}개, 빌드 가운데 ${f(at(build, .5))}·p90 ${f(at(build, .9))}·최대 ${f(build.isEmpty ? 0 : build.last)}ms, '
        '그리기 가운데 ${f(at(raster, .5))}·p90 ${f(at(raster, .9))}·최대 ${f(raster.isEmpty ? 0 : raster.last)}ms, '
        '빌드+그리기 p90 ${f(at(work, .9))}ms, 빌드나 그리기가 16.7ms 넘은 프레임 $over개';
  }

  testWidgets('신경망 첫 표시·노드 끌기·[원래대로]·[+] 프레임 시간 (노트 1만 개)', timeout: const Timeout(Duration(minutes: 20)), (
    tester,
  ) async {
    final env = Platform.environment;
    expect(env['BRAIN_VAULT'] ?? '', isNotEmpty, reason: '실제 지식 폴더 보호: BRAIN_VAULT=<사본>');
    expect(env['BRAIN_CONFIG'] ?? '', isNotEmpty, reason: '실제 설정 보호: BRAIN_CONFIG=<임시 파일>');
    report('모드: ${kProfileMode ? 'profile' : kDebugMode ? 'debug' : 'release'}, 화면 배율 ${tester.view.devicePixelRatio}');
    tester.view.physicalSize = const Size(1600, 1000) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);

    final clock = Stopwatch()..start();
    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    final container = ProviderScope.containerOf(tester.element(find.byType(SecondBrainApp)));
    // 처음 색인(새 사본)과 그물 전체 배치가 끝날 때까지 기다린다.
    while (clock.elapsed < const Duration(minutes: 8)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      final ready = container.read(notesProvider).length >= 9000 &&
          container.read(graphLayoutProvider).hasValue &&
          find.byType(GraphView).evaluate().isNotEmpty &&
          find.text('그래프 배치 중…').evaluate().isEmpty &&
          !container.read(indexingProvider);
      if (ready) break;
    }
    final notes = container.read(notesProvider).length;
    report('준비: 노트 $notes개, 색인·그물 배치까지 ${clock.elapsed.inSeconds}초');
    expect(notes, greaterThanOrEqualTo(9000));
    await settle(tester, 3000);

    final timings = <ui.FrameTiming>[];
    void onTimings(List<ui.FrameTiming> t) => timings.addAll(t);
    SchedulerBinding.instance.addTimingsCallback(onTimings);
    addTearDown(() => SchedulerBinding.instance.removeTimingsCallback(onTimings));

    Finder segment(String label) =>
        find.descendant(of: find.byType(NeuralToggle), matching: find.text(label)).first;

    // ---------------------------------------------------------------- 1. 신경망 첫 표시 (M8)
    final neuralUi = <double>[], neuralTotal = <double>[];
    for (var round = 0; round < 3; round++) {
      await settle(tester, 500);
      timings.clear();
      final before = neuralPaintCount;
      final sw = Stopwatch()..start();
      await tester.tap(segment('신경망'));
      var pumps = 0;
      while (neuralPaintCount == before && sw.elapsed < const Duration(seconds: 60)) {
        await tester.pump();
        pumps++;
        if (neuralPaintCount == before) await Future<void>.delayed(const Duration(milliseconds: 4));
      }
      final uiMs = sw.elapsedMicroseconds / 1000;
      await settle(tester, 600);
      // 노드를 처음 그린 프레임 = 화면 스레드 일이 가장 큰 프레임. 그 프레임의 그리기(raster)를 더한다.
      final firstPaint = timings.isEmpty
          ? null
          : timings.reduce((a, b) => a.buildDuration >= b.buildDuration ? a : b);
      final raster = firstPaint == null ? 0.0 : ms(firstPaint.rasterDuration);
      neuralUi.add(uiMs);
      neuralTotal.add(uiMs + raster);
      report('신경망 ${round + 1}회: 누름 → 노드 그린 프레임(화면 스레드) ${f(uiMs)}ms + 그 프레임 그리기 ${f(raster)}ms '
          '= ${f(uiMs + raster)}ms (빌드 ${f(firstPaint == null ? 0 : ms(firstPaint.buildDuration))}ms, '
          '바탕 한 번 그리기 기록 ${f(neuralLastPaintMicros / 1000)}ms, 펌프 $pumps번) | 이 구간 ${frameStats(timings)}');
      if (round == 0) await shot(tester, 'neural_first');
      // 그물로 돌아간다 (신경망 배치는 autoDispose라 다음 회는 다시 계산한다)
      await tester.tap(segment('그물'));
      await settle(tester, 1500);
      while (find.text('그래프 배치 중…').evaluate().isNotEmpty) {
        await settle(tester, 200);
      }
    }
    report('신경망 첫 표시 가운데 값: 화면 스레드 ${f(median(neuralUi))}ms, 그리기 포함 ${f(median(neuralTotal))}ms (목표 1,000ms)');
    expect(find.text('신경망 배치 중…'), findsNothing);

    // ---------------------------------------------------------------- 2. 그물 노드 끌기·[원래대로]
    final viewerFinder = find.byType(InteractiveViewer);
    TransformationController controller() => tester.widget<InteractiveViewer>(viewerFinder).transformationController!;
    final layout = container.read(graphLayoutProvider).requireValue;
    final xs = layout.values.map((p) => p.x), ys = layout.values.map((p) => p.y);
    final origin = Offset(xs.reduce(min) - 80 - graphDragRoom, ys.reduce(min) - 60 - graphDragRoom);
    final degree = <String, int>{};
    for (final l in container.read(linksProvider)) {
      if (l.isSuggested) continue;
      degree.update(l.fromId, (n) => n + 1, ifAbsent: () => 1);
      degree.update(l.toId, (n) => n + 1, ifAbsent: () => 1);
    }
    // 보통 노드(확정 연결 3개) 셋. 노트 번호가 흩어지게 고른다.
    final picks = (degree.entries.where((e) => e.value == 3 && layout.containsKey(e.key)).map((e) => e.key).toList()
          ..sort())
        .where((id) => id.hashCode % 7 == 0)
        .take(3)
        .toList();
    expect(picks.length, 3);

    final dragFirst = <double>[], dragMid = <double>[], dragP90 = <double>[], dragRasterMid = <double>[];
    final resetP90 = <double>[], resetMax = <double>[];
    for (var round = 0; round < 3; round++) {
      final id = picks[round];
      await tester.tap(find.text('맞추기'));
      await settle(tester, 600);
      // 노드를 화면 가운데로 옮겨 놓고 잡는다.
      final viewer = tester.getRect(viewerFinder);
      final m = controller().value;
      final p = layout[id]!;
      final local = Offset(p.x, p.y) - origin;
      final shift = viewer.center - (viewer.topLeft + MatrixUtils.transformPoint(m, local));
      controller().value = Matrix4.identity()
        ..translateByDouble(shift.dx, shift.dy, 0, 1)
        ..multiply(m);
      await settle(tester, 800);

      timings.clear();
      final paintsBefore = graphPaintCount;
      final g = await tester.startGesture(viewer.center, kind: PointerDeviceKind.mouse);
      final wall = <double>[];
      for (var i = 0; i < 90; i++) {
        final sw = Stopwatch()..start();
        await g.moveBy(Offset(4, i.isEven ? 2 : 1));
        await tester.pump(const Duration(milliseconds: 16));
        wall.add(sw.elapsedMicroseconds / 1000);
        if (round == 0 && i == 60) await shot(tester, 'mesh_dragging');
      }
      final dragged = graphMotionForTest?.dragging;
      final moved = graphMotionForTest?.live.length ?? 0;
      await g.up();
      await g.removePointer();
      await settle(tester, 1000);
      final dragTimings = timings.toList();
      // 끌기 첫 프레임: 기록된 첫 3프레임 가운데 화면 스레드 일이 가장 큰 것 (바탕 다시 그림 포함)
      final head = dragTimings.take(4).toList();
      final first = head.isEmpty
          ? 0.0
          : head.map((t) => ms(t.buildDuration) + ms(t.rasterDuration)).reduce(max);
      final rest = dragTimings.skip(4).take(80).toList();
      final restWork = rest.map((t) => ms(t.buildDuration) + ms(t.rasterDuration)).toList()..sort();
      final restRaster = rest.map((t) => ms(t.rasterDuration)).toList()..sort();
      final wallRest = wall.skip(3).toList()..sort();
      dragFirst.add(first);
      dragMid.add(at(restWork, .5));
      dragP90.add(at(restWork, .9));
      dragRasterMid.add(at(restRaster, .5));
      report('끌기 ${round + 1}회 ($id, 끈 노드 ${dragged ?? '없음'}, 함께 움직인 노드 $moved개, 배율 '
          '${controller().value.getMaxScaleOnAxis().toStringAsFixed(2)}): 첫 프레임 빌드+그리기 ${f(first)}ms '
          '(펌프 벽시계 ${f(wall.first)}ms), 끄는 중 빌드+그리기 가운데 ${f(at(restWork, .5))}·p90 ${f(at(restWork, .9))}·'
          '최대 ${f(restWork.isEmpty ? 0 : restWork.last)}ms (펌프 벽시계 가운데 ${f(at(wallRest, .5))}ms), 바탕 다시 그림 '
          '${graphPaintCount - paintsBefore}번 | 전체 ${frameStats(dragTimings)}');
      expect(dragged, id, reason: '노드를 잡지 못함');
      expect(graphMotionForTest!.hasMoved, isTrue);

      // [원래대로] 0.4초
      timings.clear();
      final resetWatch = Stopwatch()..start();
      await tester.tap(find.text('원래대로'));
      while (graphMotionForTest!.isResetting && resetWatch.elapsed < const Duration(seconds: 5)) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final resetMs = resetWatch.elapsedMilliseconds;
      // 끝난 뒤 바탕을 한 번 다시 그리는 프레임까지 넣고, 빈 프레임으로 값을 묽히지 않게 기다리기만 한다.
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final resetWork = timings.map((t) => ms(t.buildDuration) + ms(t.rasterDuration)).toList()..sort();
      resetP90.add(at(resetWork, .9));
      resetMax.add(resetWork.isEmpty ? 0 : resetWork.last);
      report('[원래대로] ${round + 1}회: 끝날 때까지 ${resetMs}ms, ${frameStats(timings)}, 빌드+그리기 최대 '
          '${f(resetWork.isEmpty ? 0 : resetWork.last)}ms');
      expect(graphMotionForTest!.hasMoved, isFalse, reason: '[원래대로] 뒤 옮긴 노드가 남음');
    }
    report('끌기 가운데 값(3회): 첫 프레임 ${f(median(dragFirst))}ms, 끄는 중 빌드+그리기 가운데 ${f(median(dragMid))}ms·'
        'p90 ${f(median(dragP90))}ms, 끄는 중 그리기만 가운데 ${f(median(dragRasterMid))}ms (목표 약 16ms)');
    report('[원래대로] 가운데 값(3회): 빌드+그리기 p90 ${f(median(resetP90))}ms, 최대 ${f(median(resetMax))}ms');

    // ---------------------------------------------------------------- 3. [+] 부드러운 확대
    final zoomP90 = <double>[], zoomMax = <double>[], zoomFrames = <double>[];
    for (var round = 0; round < 3; round++) {
      await tester.tap(find.text('맞추기'));
      await settle(tester, 800);
      final scale0 = controller().value.getMaxScaleOnAxis();
      timings.clear();
      final paintsBefore = graphPaintCount;
      await tester.tap(find.text('+'));
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await Future<void>.delayed(const Duration(milliseconds: 400)); // 프레임 기록이 도착하기를 기다린다
      final work = timings.map((t) => ms(t.buildDuration) + ms(t.rasterDuration)).toList()..sort();
      zoomP90.add(at(work, .9));
      zoomMax.add(work.isEmpty ? 0 : work.last);
      zoomFrames.add(timings.length.toDouble());
      report('[+] ${round + 1}회: 배율 ${scale0.toStringAsFixed(3)} → ${controller().value.getMaxScaleOnAxis().toStringAsFixed(3)}, '
          '${frameStats(timings)}, 빌드+그리기 최대 ${f(work.isEmpty ? 0 : work.last)}ms, 바탕 다시 그림 '
          '${graphPaintCount - paintsBefore}번');
      if (round == 0) await shot(tester, 'mesh_zoomed');
    }
    report('[+] 가운데 값(3회): 빌드+그리기 p90 ${f(median(zoomP90))}ms, 최대 ${f(median(zoomMax))}ms');
  });
}
