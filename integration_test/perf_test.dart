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
    // 합격 기준 (K-38, 11/12): 디버그(JIT)·작은 지식 폴더 사본 기준 실측의 약 3~5배. 목표값(설계서 5.8)이 아니라
    // "크게 느려졌다"를 잡는 선이다. 11/12 실측: 첫 표시 1,001ms, 끌기·마우스·휠 다시 그림 0번, 화면 이동 가운데 값 56~172ms.
    expect(start.elapsedMilliseconds, lessThan(5000), reason: '그래프 첫 표시가 5초를 넘음');
    await settle(tester, 1500);

    final timings = <ui.FrameTiming>[];
    void onTimings(List<ui.FrameTiming> t) => timings.addAll(t);

    Future<({int janky, double p90Build, int repaints})> measure(
      String name,
      Future<void> Function() action, {
      int Function()? count,
    }) async {
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
      // 타이머 안에서 화면 스레드를 막는 일(색인 동기화 등)은 빌드 시간에 안 잡히고 다음 프레임 시작을 늦춘다.
      final lag = timings.isEmpty ? 0 : timings.map((t) => ms(t.vsyncOverhead)).reduce((a, b) => a > b ? a : b);
      debugPrint(
        '[성능] $name: 프레임 ${timings.length}개, 빌드 평균 ${avg(build).toStringAsFixed(1)}ms·p90 ${p90(build).toStringAsFixed(1)}ms, '
        '그리기 평균 ${avg(raster).toStringAsFixed(1)}ms·p90 ${p90(raster).toStringAsFixed(1)}ms, 16.7ms 넘은 프레임 $janky개, 가장 긴 빌드 ${worst.toStringAsFixed(0)}ms, 가장 긴 프레임 시작 지연 ${lag.toStringAsFixed(0)}ms'
        '${count == null ? '' : ', 다시 그림 ${count() - before}번'} (${watch.elapsedMilliseconds}ms)',
      );
      return (janky: janky, p90Build: p90(build), repaints: (count?.call() ?? 0) - before);
    }

    // 앱 밖에서 노트 1개가 생길 때(자동 저장·Obsidian) 화면이 멈추는 정도: 폴더 감시 → 색인 → 목록·연결 → 그래프
    final vaultRoot = Platform.environment['BRAIN_VAULT'];
    if (vaultRoot != null && Platform.environment['PERF_SKIP_EXTERNAL'] != '1') {
      final file = File('$vaultRoot/wiki/성능 시험/외부에서 생긴 노트.md');
      await measure('앱 밖에서 노트 1개 생김 (2.5초 지켜봄)', () async {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('---\nid: n_99999\ntitle: "외부에서 생긴 노트"\nsummary: "성능 시험용"\n---\n\n결제 웹훅 재시도 시험 노트\n');
        await settle(tester, 2500);
      });
      file.parent.deleteSync(recursive: true);
      await settle(tester, 1500);
    }

    final graph = find.byType(GraphView);
    expect(graph, findsOneWidget);
    final center = tester.getCenter(graph);

    final drag = await measure('그래프 끌기 40프레임', () async {
      final g = await tester.startGesture(center);
      for (var i = 0; i < 40; i++) {
        await g.moveBy(const Offset(6, 3));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
    }, count: () => graphPaintCount);

    final hover = await measure('그래프 위 마우스 이동 60번', () async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: center - const Offset(300, 200));
      for (var i = 0; i < 60; i++) {
        await mouse.moveBy(const Offset(10, 6.5));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await mouse.removePointer();
    }, count: () => graphPaintCount);

    final wheel = await measure('그래프 휠 확대·축소 30번', () async {
      for (var i = 0; i < 30; i++) {
        tester.binding.handlePointerEvent(
          PointerScrollEvent(position: center, scrollDelta: Offset(0, i < 15 ? -40 : 40)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
    }, count: () => graphPaintCount);

    // 끌기·마우스·휠은 이미 그린 층을 옮기기만 해야 한다 (11/07: 끌기 40프레임에 37번 다시 그림 → 0번).
    for (final (name, r) in [('끌기', drag), ('마우스', hover), ('휠', wheel)]) {
      expect(r.repaints, lessThanOrEqualTo(3), reason: '$name 중 그래프를 다시 그림 ${r.repaints}번');
      expect(r.p90Build, lessThan(30), reason: '$name 빌드 p90 ${r.p90Build}ms');
    }
    // "16.7ms 넘은 프레임"은 단언하지 않는다: 시험 앱 창이 앞으로 안 나오면("Failed to foreground app") 프레임 간격이
    // 약 193ms로 묶여 모든 프레임이 넘는다(11/12 두 번째 실행 44/44, 첫 실행 1/86). 빌드 시간·다시 그림만 본다.

    // 화면 이동: 메뉴를 눌러 화면이 뜨는 동안 가장 긴 프레임 (사용자가 '멈칫'으로 느끼는 것).
    // 한 번 재면 흔들림이 커서 5바퀴 돌고 가운데 값을 쓴다.
    const menus = ['노트', 'AI 질문', '배운 것', '할 일', '가져오기', '연동', '설정', '홈'];
    final worst = {for (final m in menus) m: <double>[]};
    for (var round = 0; round < 5; round++) {
      for (final menu in menus) {
        await settle(tester, 200);
        timings.clear();
        SchedulerBinding.instance.addTimingsCallback(onTimings);
        final paintsBefore = graphPaintCount;
        await tester.tap(find.text(menu).first);
        await settle(tester, 300);
        SchedulerBinding.instance.removeTimingsCallback(onTimings);
        if (menu == '홈') {
          final slow = timings.where((t) => t.buildDuration.inMilliseconds > 50).map((t) => t.buildDuration.inMilliseconds).toList();
          debugPrint('[성능] 홈 $round바퀴: 그래프 그림 ${graphPaintCount - paintsBefore}번, 50ms 넘은 프레임 $slow');
        }
        worst[menu]!.add(timings.isEmpty ? 0 : timings.map((t) => t.buildDuration.inMicroseconds / 1000).reduce((a, b) => a > b ? a : b));
      }
    }
    for (final m in menus) {
      final v = worst[m]!..sort();
      debugPrint('[성능] 화면 이동 → $m: 가장 긴 빌드 가운데 값 ${v[v.length ~/ 2].toStringAsFixed(0)}ms (5번: ${v.map((x) => x.toStringAsFixed(0)).join('·')})');
      expect(v[v.length ~/ 2], lessThan(600), reason: '화면 이동 → $m 가장 긴 빌드 가운데 값이 600ms를 넘음');
    }

    await tester.tap(find.text('목록'));
    await settle(tester, 1000);
    final list = find.descendant(of: find.byType(StructureListView), matching: find.byType(Scrollable)).first;
    // 스크롤은 "16.7ms 넘은 프레임"이 시험 환경에서 늘 다 넘게 나와(프레임 간격이 시험 펌프에 묶임) 빌드 시간만 본다.
    final scroll = await measure('구조 목록 스크롤 40프레임', () async {
      final g = await tester.startGesture(tester.getCenter(list));
      for (var i = 0; i < 40; i++) {
        await g.moveBy(const Offset(0, -8));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
    }, count: () => structureListBuildCount);
    expect(scroll.p90Build, lessThan(30), reason: '목록 스크롤 빌드 p90 ${scroll.p90Build}ms');
  });
}
