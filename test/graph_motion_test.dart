import 'dart:math';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secondbrain/app/theme/app_theme.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:secondbrain/features/home/graph_view.dart';
import 'package:secondbrain/features/home/neural_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 그래프 움직임 (설계서_프롬프트이후 5.6): 부드러운 확대·축소.
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

  // 그물: a─b─c 한 줄 + 멀리 떨어진 z (끌기 시험에서 "멀리 있는 노드는 그대로"를 본다)
  final notes = [doc('a', '결제'), doc('b', '결제'), doc('c', '결제'), doc('z', '배포')];
  const links = [
    NoteLink(fromId: 'a', toId: 'b', kind: 'link'),
    NoteLink(fromId: 'b', toId: 'c', kind: 'link'),
  ];
  const layout = {'a': Point(0.0, 0.0), 'b': Point(90.0, 0.0), 'c': Point(180.0, 0.0), 'z': Point(180.0, 220.0)};

  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, Widget child, {NeuralLayout? neural}) async {
    tester.view.physicalSize = const Size(1000, 700) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        notesProvider.overrideWithValue(notes),
        linksProvider.overrideWithValue(links),
        graphLayoutProvider.overrideWith((ref) async => layout),
        if (neural != null) neuralLayoutProvider.overrideWith((ref) async => neural),
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
}
