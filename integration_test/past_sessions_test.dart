import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/features/connect/claude_code_providers.dart';

/// 지난 대화 정리를 실제 앱 화면에서 버튼으로 돌려 본다 (실제 Claude Code를 부르므로 사용량이 든다).
///
/// flutter test integration_test/past_sessions_test.dart -d macos \
///   --dart-define=START_PAGE=/connect --dart-define=PROJECT=<프로젝트 이름>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() isDone, {
    required Duration timeout,
    void Function()? onTick,
  }) async {
    final end = DateTime.now().add(timeout);
    var tick = 0;
    while (!isDone()) {
      if (DateTime.now().isAfter(end)) fail('시간 초과 ($timeout)');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();
      if (++tick % 20 == 0) onTick?.call();
    }
  }

  testWidgets('지난 대화 정리: 세션 하나를 버튼으로 정리', (tester) async {
    // 실제 지식 폴더·설정을 건드리지 않게 사본으로만 돈다 (11/11 K-38)
    expect(Platform.environment['BRAIN_VAULT'] ?? '', isNotEmpty, reason: '실제 지식 폴더 보호: BRAIN_VAULT=<사본>');
    expect(Platform.environment['BRAIN_CONFIG'] ?? '', isNotEmpty, reason: '실제 설정 보호: BRAIN_CONFIG=<임시 파일>');
    const project = String.fromEnvironment('PROJECT');
    expect(project, isNotEmpty, reason: '--dart-define=PROJECT=... 필요');

    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    await tester.pump(const Duration(seconds: 1));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SecondBrainApp)),
    );
    final controller = container.read(pastSessionsProvider.notifier);
    PastSessionsState state() => container.read(pastSessionsProvider);

    await tester.ensureVisible(find.text('세션 목록 불러오기'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('세션 목록 불러오기'));
    await waitUntil(
      tester,
      () => state().isLoaded,
      timeout: const Duration(minutes: 2),
    );
    debugPrint(
      '[시험] 세션 ${state().sessions.length}개, 프로젝트 ${state().unsavedByProject}',
    );
    expect(state().unsavedByProject.containsKey(project), isTrue);

    for (final other in state().unsavedByProject.keys.toList()) {
      if (other != project) controller.toggleProject(other);
    }
    await tester.pump();
    debugPrint('[시험] 대상 ${state().targets.map((s) => s.shortId).toList()}');

    final start = DateTime.now();
    await tester.ensureVisible(find.text('동의하고 정리 시작'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('동의하고 정리 시작'));
    await tester.pump();
    expect(state().isRunning, isTrue);
    await waitUntil(
      tester,
      () => !state().isRunning,
      timeout: const Duration(minutes: 10),
      onTick: () => debugPrint(
        '[시험] ${DateTime.now().difference(start).inSeconds}초 '
        '${state().done}/${state().total} ${state().current?.shortId ?? ''}',
      ),
    );
    debugPrint(
      '[시험] 끝 ${DateTime.now().difference(start).inSeconds}초, 오류 ${state().error}',
    );
    for (final line in state().log) {
      debugPrint('[시험] $line');
    }
    expect(state().error, isNull);
    expect(state().done, state().total);
  });
}
