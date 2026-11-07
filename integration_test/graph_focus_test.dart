import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:secondbrain/features/home/graph_view.dart';

/// 노드를 고르면 나머지를 흐리게 하는 막이, 그래프를 축소해 그림이 화면보다 작아져도
/// 보이는 영역 전체를 덮는다 (11/07 사용자 지적: 축소하면 검은 네모로 보임).
///
/// BRAIN_CONFIG=<시험용> BRAIN_VAULT=<사본> flutter test integration_test/graph_focus_test.dart -d macos \
///   [--dart-define=SHOT_DIR=<캡처 폴더>]
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const shotDir = String.fromEnvironment('SHOT_DIR');

  Future<void> settle(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (shotDir.isEmpty) return;
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final image = await layer.toImage(Offset.zero & (view.size * 2), pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$shotDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  testWidgets('축소한 그래프에서 노드를 골라도 막이 보이는 영역 전체를 덮는다', (tester) async {
    expect(Platform.environment['BRAIN_CONFIG'], isNotNull, reason: '사용자 설정 보호');
    tester.view.physicalSize = const Size(1600, 1000) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    await settle(tester, 3000);
    final container = ProviderScope.containerOf(tester.element(find.byType(SecondBrainApp)));

    // 그래프를 축소해 그림이 보이는 영역보다 작아지게 한다 (− 4번).
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('−'));
      await settle(tester, 200);
    }
    final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final viewport = tester.getSize(find.byType(InteractiveViewer));
    final scale = viewer.transformationController!.value.getMaxScaleOnAxis();
    final content = tester.getSize(
      find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(SizedBox)).first,
    );
    debugPrint('[시험] 보이는 영역 $viewport, 그림 ${content * scale} (배율 ${scale.toStringAsFixed(2)})');
    // 시험이 실제로 "그림이 영역보다 작은" 상황을 만들었는지 먼저 확인한다 (L-0006).
    expect(content.width * scale, lessThan(viewport.width), reason: '축소가 안 돼 시험 조건이 안 만들어짐');

    final veil = find.byWidgetPredicate((w) => w is ColoredBox && w.color == const Color(0x660d0b18));
    expect(veil, findsOneWidget);
    double opacity() => tester
        .widget<AnimatedOpacity>(find.ancestor(of: veil, matching: find.byType(AnimatedOpacity)))
        .opacity;
    expect(opacity(), 0, reason: '아무것도 안 골랐으면 막이 없다');
    await shot(tester, 'focus_before');

    final id = container.read(notesProvider).first.id;
    container.read(selectedNoteProvider.notifier).select(id);
    await settle(tester, 600);
    expect(opacity(), 1);
    expect(tester.getSize(veil), viewport, reason: '막은 그림 크기가 아니라 보이는 영역 전체');
    expect(tester.getTopLeft(veil), tester.getTopLeft(find.byType(InteractiveViewer)));
    await shot(tester, 'focus_zoomed_out');

    container.read(selectedNoteProvider.notifier).select(null);
    await settle(tester, 400);
    expect(opacity(), 0);
    expect(find.byType(GraphView), findsOneWidget);
  });
}
