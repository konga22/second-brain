import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/core/app_config_provider.dart';
import 'package:secondbrain/features/home/graph_view.dart';
import 'package:secondbrain/shared/zoom_scope.dart';

/// 그래프 화면에서 ⌘+ / ⌘- 를 눌러도 그래프가 다시 맞춰지지 않는다 (11/07 떨림 회귀 시험).
/// 사용자 설정을 건드리지 않게 `BRAIN_CONFIG`로 시험용 설정 파일을 쓴다 (없으면 시험을 멈춘다).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
  }

  Future<void> cmd(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  }

  testWidgets('그래프 화면에서 화면 배율을 바꿔도 떨리지 않는다', (tester) async {
    // 실제 지식 폴더·설정을 건드리지 않게 사본으로만 돈다 (11/11 K-38)
    expect(Platform.environment['BRAIN_VAULT'] ?? '', isNotEmpty, reason: '실제 지식 폴더 보호: BRAIN_VAULT=<사본>');
    expect(Platform.environment['BRAIN_CONFIG'] ?? '', isNotEmpty, reason: '실제 설정 보호: BRAIN_CONFIG=<임시 파일>');
    expect(
      Platform.environment['BRAIN_CONFIG'],
      isNotNull,
      reason: 'BRAIN_CONFIG=<시험용 config.json> 로 돌린다 (사용자 설정 보호)',
    );
    // 시험 창이 좁으면(논리 폭 1100 미만) 배율 제한 때문에 ⌘+가 아무 일도 안 한다. 사용자 창 크기로 맞춘다.
    tester.view.physicalSize = const Size(1600, 1000) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    await settle(tester, 3000);
    final container = ProviderScope.containerOf(tester.element(find.byType(SecondBrainApp)));
    const original = 1.0;
    expect(find.byType(GraphView), findsOneWidget);
    final fitsBefore = graphFitCount;
    expect(fitsBefore, greaterThan(0), reason: '처음 한 번은 맞춘다');
    // 그래프 영역 가운데가 가리키는 그래프 좌표 (배율을 바꿔도 그대로여야 한다).
    Offset worldCenter() {
      final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      final size = tester.getSize(find.byType(InteractiveViewer));
      return MatrixUtils.transformPoint(
        Matrix4.inverted(viewer.transformationController!.value),
        size.center(Offset.zero),
      );
    }

    // 앱 전체 배율 (ZoomScope의 Transform.scale).
    double appScale() => tester
        .widget<Transform>(
          find.descendant(of: find.byType(ZoomScope), matching: find.byType(Transform)).first,
        )
        .transform
        .getMaxScaleOnAxis();

    // 시험용 설정은 앞 시험이 남긴 배율로 시작할 수 있어 1.0에서 시작한다.
    container.read(appConfigProvider.notifier).update((c) => c.copyWith(uiScale: 1.0));
    await settle(tester, 600);
    // 디버그 빌드는 프레임이 가끔 100ms를 넘어 180ms 애니메이션이 한두 프레임에 끝날 수 있다.
    // 애니메이션을 5배 느리게 돌려 기계 속도와 관계없이 중간 프레임을 본다.
    timeDilation = 5;
    final center0 = worldCenter();
    for (final (key, up) in [
      (LogicalKeyboardKey.equal, true),
      (LogicalKeyboardKey.equal, true),
      (LogicalKeyboardKey.equal, true),
      (LogicalKeyboardKey.minus, false),
      (LogicalKeyboardKey.minus, false),
    ]) {
      await cmd(tester, key);
      // 16ms마다 배율을 재서 한 번에 뛰지 않고 한 방향으로만 부드럽게 바뀌는지 본다.
      final samples = <double>[appScale()];
      for (var i = 0; i < 70; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        samples.add(appScale());
      }
      final steps = <double>[];
      for (var i = 1; i < samples.length; i++) {
        final d = samples[i] - samples[i - 1];
        if (d.abs() > 1e-6) steps.add(d);
      }
      debugPrint('[시험] ${up ? '⌘+' : '⌘-'} 배율 ${samples.first.toStringAsFixed(3)} → ${samples.last.toStringAsFixed(3)}, 중간 프레임 ${steps.length}개');
      expect(steps.length, greaterThanOrEqualTo(4), reason: '배율이 한 프레임에 뛰면 끊겨 보인다');
      expect(steps.every((d) => up ? d > 0 : d < 0), isTrue, reason: '중간에 거꾸로 가면 덜덜 떨린다');
      final drift = (worldCenter() - center0).distance;
      expect(drift, lessThan(1.0), reason: '그래프 가운데가 그대로여야 한다 (움직임 $drift)');
      await settle(tester, 200);
    }
    timeDilation = 1; // 시험 본문 안에서 되돌려야 한다 (끝난 뒤 검사가 먼저 돈다)
    debugPrint('[시험] 배율 ${container.read(appConfigProvider).uiScale}, 맞추기 $fitsBefore → $graphFitCount');
    final after = container.read(appConfigProvider).uiScale;
    // 사용자 설정을 원래 값으로 되돌린다 (⌘±는 설정 파일에 저장하므로).
    container.read(appConfigProvider.notifier).update((c) => c.copyWith(uiScale: original));
    expect(after, closeTo(original + 0.1, 0.001));
    expect(graphFitCount, fitsBefore, reason: '배율이 바뀌어도 다시 맞추지 않아야 떨리지 않는다');
  });
}
