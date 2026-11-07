import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:secondbrain/features/home/graph_view.dart';

/// 앱 시작이 어디서 시간을 쓰는지 나눠 잰다 (설계서 5.8 그래프 첫 표시 1초, 11/07 노트 1만 개에서 2.2초).
/// flutter drive --profile --driver=test_driver/integration_test.dart --target=integration_test/startup_profile_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('앱 시작 시간 나눠 재기', (tester) async {
    expect(Platform.environment['BRAIN_CONFIG'], isNotNull);
    final w = Stopwatch()..start();
    void lap(String name) {
      debugPrint('[시작] $name ${w.elapsedMilliseconds}ms');
      w.reset();
    }

    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(vaultProvider);
    lap('지식 폴더');
    c.read(searchIndexProvider);
    lap('색인 열기');
    c.read(notesProvider);
    lap('notes()');
    c.read(linksProvider);
    lap('links()');
    await c.read(graphLayoutProvider.future);
    lap('그래프 위치');
    c.read(rawDocsProvider);
    lap('원본 목록');
    c.read(lessonsProvider);
    lap('실수 노트');
    c.read(searchIndexProvider).topics();
    lap('주제 목록');

    tester.view.physicalSize = const Size(1600, 1000) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    w.reset();
    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    lap('첫 프레임(앱 전체 build·layout·paint)');
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (find.byType(GraphView).evaluate().isNotEmpty && find.text('그래프 배치 중…').evaluate().isEmpty) break;
    }
    lap('그래프 보일 때까지');
  });
}
