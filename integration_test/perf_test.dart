import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/features/home/graph_view.dart';
import 'package:secondbrain/features/home/structure_list_view.dart';

/// 랙 측정 (11/07 "앱이 랙 걸려"): 그래프 끌기·마우스 올리기·휠 확대, 구조 목록 스크롤을 하며
/// 프레임 시간(빌드·그리기)과 다시 그린 횟수를 잰다. 숫자는 docs/개발진행.md "앱 랙 최적화"에 적는다.
///
/// BRAIN_CONFIG=<시험용 config.json> BRAIN_VAULT=<지식 폴더 사본> \
///   flutter test integration_test/perf_test.dart -d macos [--profile]
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
  }

  testWidgets('그래프·목록 조작 때 프레임 시간', (tester) async {
    expect(Platform.environment['BRAIN_CONFIG'], isNotNull, reason: '사용자 설정 보호');
    tester.view.physicalSize = const Size(1600, 1000) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    final start = Stopwatch()..start();
    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    // 그래프 첫 표시: 배치가 끝나 '그래프 배치 중…'이 사라질 때까지 (설계서 5.8 목표 1초, 저장된 위치 사용 시)
    while (start.elapsed < const Duration(seconds: 90)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      if (find.byType(GraphView).evaluate().isNotEmpty && find.text('그래프 배치 중…').evaluate().isEmpty) break;
    }
    debugPrint('[성능] 앱 시작 → 그래프 첫 표시 ${start.elapsedMilliseconds}ms (노트 ${find.byType(GraphView).evaluate().isEmpty ? '?' : 'OK'})');
    await settle(tester, 1500);

    final timings = <ui.FrameTiming>[];
    void onTimings(List<ui.FrameTiming> t) => timings.addAll(t);

    Future<void> measure(String name, Future<void> Function() action, {int Function()? count}) async {
      await settle(tester, 300);
      timings.clear();
      final before = count?.call() ?? 0;
      final watch = Stopwatch()..start();
      SchedulerBinding.instance.addTimingsCallback(onTimings);
      await action();
      await settle(tester, 300);
      SchedulerBinding.instance.removeTimingsCallback(onTimings);
      watch.stop();
      double ms(Duration d) => d.inMicroseconds / 1000;
      final build = timings.map((t) => ms(t.buildDuration)).toList()..sort();
      final raster = timings.map((t) => ms(t.rasterDuration)).toList()..sort();
      double avg(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
      double p90(List<double> v) => v.isEmpty ? 0 : v[(v.length * 0.9).floor().clamp(0, v.length - 1)];
      final janky = timings.where((t) => ms(t.totalSpan) > 16.7).length;
      final worst = build.isEmpty ? 0 : build.last;
      debugPrint(
        '[성능] $name: 프레임 ${timings.length}개, 빌드 평균 ${avg(build).toStringAsFixed(1)}ms·p90 ${p90(build).toStringAsFixed(1)}ms, '
        '그리기 평균 ${avg(raster).toStringAsFixed(1)}ms·p90 ${p90(raster).toStringAsFixed(1)}ms, 16.7ms 넘은 프레임 $janky개, 가장 긴 빌드 ${worst.toStringAsFixed(0)}ms'
        '${count == null ? '' : ', 다시 그림 ${count() - before}번'} (${watch.elapsedMilliseconds}ms)',
      );
    }

    final graph = find.byType(GraphView);
    expect(graph, findsOneWidget);
    final center = tester.getCenter(graph);

    await measure('그래프 끌기 40프레임', () async {
      final g = await tester.startGesture(center);
      for (var i = 0; i < 40; i++) {
        await g.moveBy(const Offset(6, 3));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
    }, count: () => graphPaintCount);

    await measure('그래프 위 마우스 이동 60번', () async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: center - const Offset(300, 200));
      for (var i = 0; i < 60; i++) {
        await mouse.moveBy(const Offset(10, 6.5));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await mouse.removePointer();
    }, count: () => graphPaintCount);

    await measure('그래프 휠 확대·축소 30번', () async {
      for (var i = 0; i < 30; i++) {
        tester.binding.handlePointerEvent(
          PointerScrollEvent(position: center, scrollDelta: Offset(0, i < 15 ? -40 : 40)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
    }, count: () => graphPaintCount);

    // 화면 이동: 메뉴를 눌러 화면이 뜨는 동안 가장 긴 프레임 (사용자가 '멈칫'으로 느끼는 것).
    // 한 번 재면 흔들림이 커서 5바퀴 돌고 가운데 값을 쓴다.
    const menus = ['노트', 'AI 질문', '배운 것', '할 일', '가져오기', '연동', '설정', '홈'];
    final worst = {for (final m in menus) m: <double>[]};
    for (var round = 0; round < 5; round++) {
      for (final menu in menus) {
        await settle(tester, 200);
        timings.clear();
        SchedulerBinding.instance.addTimingsCallback(onTimings);
        await tester.tap(find.text(menu).first);
        await settle(tester, 300);
        SchedulerBinding.instance.removeTimingsCallback(onTimings);
        worst[menu]!.add(timings.isEmpty ? 0 : timings.map((t) => t.buildDuration.inMicroseconds / 1000).reduce((a, b) => a > b ? a : b));
      }
    }
    for (final m in menus) {
      final v = worst[m]!..sort();
      debugPrint('[성능] 화면 이동 → $m: 가장 긴 빌드 가운데 값 ${v[v.length ~/ 2].toStringAsFixed(0)}ms (5번: ${v.map((x) => x.toStringAsFixed(0)).join('·')})');
    }

    await tester.tap(find.text('목록'));
    await settle(tester, 1000);
    final list = find.descendant(of: find.byType(StructureListView), matching: find.byType(Scrollable)).first;
    await measure('구조 목록 스크롤 40프레임', () async {
      final g = await tester.startGesture(tester.getCenter(list));
      for (var i = 0; i < 40; i++) {
        await g.moveBy(const Offset(0, -8));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
    }, count: () => structureListBuildCount);
  });
}
