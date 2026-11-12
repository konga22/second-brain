import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/core/brain_providers.dart';

/// 처음 색인(새 폴더·스키마를 올린 첫 실행)이 화면을 멈추지 않는지 (11/11 K-32 나머지).
///
/// 예전에는 화면 스레드의 색인 열기(`SearchIndex.open`)가 다시 만들기를 해, 노트 1만 개면 첫 화면이 그동안 안 나왔다.
/// BRAIN_VAULT=<1만 개 폴더의 새 사본(색인 없음)> BRAIN_CONFIG=<임시 파일> flutter test integration_test/first_index_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('노트 1만 개 처음 색인 중에도 화면이 돈다', (tester) async {
    expect(Platform.environment['BRAIN_VAULT'] ?? '', isNotEmpty, reason: '실제 지식 폴더 보호');
    expect(Platform.environment['BRAIN_CONFIG'] ?? '', isNotEmpty, reason: '실제 설정 보호');
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    final clock = Stopwatch()..start();
    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    final firstFrame = clock.elapsedMilliseconds;
    final container = ProviderScope.containerOf(tester.element(find.byType(SecondBrainApp)));

    var longest = 0;
    var last = clock.elapsedMilliseconds;
    var sawIndexing = false;
    while (clock.elapsed < const Duration(minutes: 3)) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      await tester.pump();
      final now = clock.elapsedMilliseconds;
      if (now - last > longest) longest = now - last;
      last = now;
      final isIndexing = container.read(indexingProvider);
      sawIndexing |= isIndexing;
      if (sawIndexing && !isIndexing) break;
    }
    // 목록은 번호가 오른 뒤 백그라운드에서 다시 읽는다
    var notes = 0;
    for (var i = 0; i < 100 && notes < 9000; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      notes = container.read(notesProvider).length;
    }
    debugPrint('[처음 색인] 첫 프레임 ${firstFrame}ms, 색인 끝까지 ${clock.elapsedMilliseconds}ms, 화면 가장 긴 멈춤 ${longest}ms, 노트 $notes개');
    expect(sawIndexing, isTrue);
    expect(notes, greaterThan(9000));
    expect(firstFrame, lessThan(3000), reason: '예전에는 첫 프레임이 처음 색인이 끝날 때까지 안 나왔다');
    tester.view.resetPhysicalSize();
  });
}
