import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/features/connect/auto_tidy.dart';
import 'package:secondbrain/features/connect/claude_code_providers.dart';

/// 자동 정리·지난 대화 정리의 세션 목록 읽기가 앱 안(백그라운드 isolate)에서 되는지 본다.
/// 정리는 하지 않는다 (비용 없음). 11/07 "보낼 수 없는 객체" 오류 회귀 시험.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('자동 정리 미리 보기·지난 대화 목록 읽기', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final targets = await container.read(autoTidyProvider.notifier).preview();
    debugPrint('[시험] 자동 정리 대상 ${targets.length}개');
    await container.read(pastSessionsProvider.notifier).load();
    final sessions = container.read(pastSessionsProvider).sessions;
    debugPrint('[시험] 지난 대화 ${sessions.length}개');
    expect(sessions, isNotEmpty);
    expect(targets.length, lessThanOrEqualTo(sessions.length));
  });
}
