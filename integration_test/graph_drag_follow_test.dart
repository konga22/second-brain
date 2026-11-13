import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:secondbrain/features/home/graph_view.dart';

/// 실제 앱(맥 창)에서 그물 보기 노드 끌기 좌표를 확인한다 (설계서_프롬프트이후 5.6, 11/14 실제 앱에서 발견).
///
/// 11/14 성능 시험 캡처에서 노드를 끄는 동안 연결선이 그래프 위로 솟아 주제 칩 뒤로 들어갔다. 위젯 시험에는 없는
/// 처음 사용 카드·주제 칩 다섯 줄·화면 배율 2·옮긴 변환이 모두 있는 실제 창에서 본다:
/// 1. [맞추기] 뒤 맨 위 노드가 주제 칩 아래에 있다 (원인: 도구 줄 자리를 칩 두 줄로 못박음 → 고침).
/// 2. 노드를 끌면 끈 노드가 손(포인터) 밑에 그대로 있다 (0.5px 안).
///
/// 노트 1만 개 합성 폴더 사본으로만 돈다 (실제 지식 폴더·설정 보호):
/// BRAIN_VAULT=<사본> BRAIN_CONFIG=<임시 파일> flutter drive --profile \
///   --driver=test_driver/integration_test.dart --target=integration_test/graph_drag_follow_test.dart -d macos \
///   [--dart-define=SHOT_DIR=<캡처 폴더>]
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const shotDir = String.fromEnvironment('SHOT_DIR');

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
    final image = await layer.toImage(Offset.zero & (view.size * tester.view.devicePixelRatio), pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$shotDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  // profile 모드에서는 Offset.toString이 줄어 있어 직접 적는다.
  String o(Offset v) => '(${v.dx.toStringAsFixed(1)}, ${v.dy.toStringAsFixed(1)})';

  testWidgets('노드를 끌면 손 밑에 따라오고, [맞추기]는 그래프를 주제 칩 아래에 둔다 (노트 1만 개)', timeout: const Timeout(Duration(minutes: 10)), (
    tester,
  ) async {
    final env = Platform.environment;
    expect(env['BRAIN_VAULT'] ?? '', isNotEmpty, reason: '실제 지식 폴더 보호: BRAIN_VAULT=<사본>');
    expect(env['BRAIN_CONFIG'] ?? '', isNotEmpty, reason: '실제 설정 보호: BRAIN_CONFIG=<임시 파일>');
    tester.view.physicalSize = const Size(1600, 1000) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    final clock = Stopwatch()..start();
    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    final container = ProviderScope.containerOf(tester.element(find.byType(SecondBrainApp)));
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
    expect(container.read(notesProvider).length, greaterThanOrEqualTo(9000));
    await settle(tester, 2000);

    final viewerFinder = find.byType(InteractiveViewer);
    TransformationController controller() => tester.widget<InteractiveViewer>(viewerFinder).transformationController!;
    final layout = container.read(graphLayoutProvider).requireValue;
    // 그림 원점: 노드 범위 왼쪽 위 - 여백 80·60 - 끌기 여유. 끌기 여유는 배율에 따라 바뀌어 그때그때 읽는다 (5.6, 11/14).
    Offset origin() => graphContentForTest.origin;
    final viewer = tester.getRect(viewerFinder);
    Offset screen(Point<double> p) => viewer.topLeft + MatrixUtils.transformPoint(controller().value, Offset(p.x, p.y) - origin());

    // 1. [맞추기]: 맨 위 노드가 주제 칩 묶음 아래
    await tester.tap(find.text('맞추기'));
    await settle(tester, 600);
    final chipsBottom = tester.getRect(find.ancestor(of: find.text('모든 폴더'), matching: find.byType(Wrap)).first).bottom;
    final topId = layout.keys.reduce((a, b) => layout[a]!.y <= layout[b]!.y ? a : b);
    debugPrint('[DRAG] 화면 배율 ${tester.view.devicePixelRatio}, 그래프 영역 ${o(viewer.topLeft)}~${o(viewer.bottomRight)}, '
        '칩 아래 끝 ${chipsBottom.toStringAsFixed(1)}, 맨 위 노드 $topId ${o(screen(layout[topId]!))}, '
        '배율 ${controller().value.getMaxScaleOnAxis().toStringAsFixed(3)}');
    await shot(tester, 'drag_follow_fit');
    expect(screen(layout[topId]!).dy, greaterThan(chipsBottom), reason: '맞춘 그래프의 맨 위 노드가 주제 칩 뒤에 가림');

    // 2. 끌기: 보통 노드(연결 3개)를 가운데로 옮겨 놓고(옮긴 변환) 오른쪽 아래로 끈다
    final degree = <String, int>{};
    for (final l in container.read(linksProvider)) {
      if (l.isSuggested) continue;
      degree.update(l.fromId, (n) => n + 1, ifAbsent: () => 1);
      degree.update(l.toId, (n) => n + 1, ifAbsent: () => 1);
    }
    final id = (degree.entries.where((e) => e.value == 3 && layout.containsKey(e.key)).map((e) => e.key).toList()..sort())
        .first;
    final m = controller().value;
    final shift = viewer.center - screen(layout[id]!);
    controller().value = Matrix4.identity()
      ..translateByDouble(shift.dx, shift.dy, 0, 1)
      ..multiply(m);
    await settle(tester, 800);
    final start = screen(layout[id]!);
    // 먼저 골라 둔다: 고른 노드는 위 층(_FocusPainter)이 흰 점·이름표로 그려 캡처에서 끈 노드가 보이고,
    // 그 층의 좌표도 함께 확인된다.
    await tester.tapAt(start, kind: PointerDeviceKind.mouse);
    await settle(tester, 800);
    expect(container.read(selectedNoteProvider), id, reason: '끌 노드를 고르지 못함');
    final g = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    var pointer = start;
    var worst = 0.0;
    for (var i = 0; i < 40; i++) {
      await g.moveBy(const Offset(4, 2));
      pointer += const Offset(4, 2);
      await tester.pump(const Duration(milliseconds: 16));
      final p = graphMotionForTest!.moved[id];
      if (p != null) worst = max(worst, (screen(p) - pointer).distance);
    }
    final motion = graphMotionForTest!;
    final at = screen(motion.moved[id] ?? layout[id]!);
    debugPrint('[DRAG] 노드 $id: 시작 ${o(start)} → 포인터 ${o(pointer)}, 노드 화면 자리 ${o(at)}, '
        '끄는 동안 가장 큰 어긋남 ${worst.toStringAsFixed(2)}px, 함께 움직인 노드 ${motion.live.length}개');
    await shot(tester, 'drag_follow_dragging');
    expect(motion.dragging, id, reason: '노드를 잡지 못함');
    expect((at - pointer).distance, lessThan(0.5), reason: '끈 노드가 손 밑에 있어야 한다');
    expect(worst, lessThan(0.5));
    await g.up();
    await g.removePointer();
    await settle(tester, 1500);
    await tester.tap(find.text('원래대로'));
    await settle(tester, 1000);
    expect(graphMotionForTest!.hasMoved, isFalse);
  });
}
