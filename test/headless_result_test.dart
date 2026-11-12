import 'package:flutter_test/flutter_test.dart';
import 'package:secondbrain/core/claude_code.dart';

// 실제 `claude -p --output-format stream-json`(Claude Code 2.1.322)의 마지막 result 이벤트에서
// 필요한 칸만 옮긴 것 (11/12 실측: 예산 0.10달러·0.30달러로 지난 세션 정리).
void main() {
  test('예산 한도에 닿으면 빈 메시지가 아니라 이유와 쓴 돈을 돌려준다', () {
    final result = HeadlessResult.fromEvent({
      'type': 'result',
      'subtype': 'error_max_budget_usd',
      'is_error': true,
      'num_turns': 1,
      'total_cost_usd': 0.105516,
      'errors': ['Reached maximum budget (\$0.1)'],
    }, exitCode: 1);
    expect(result.ok, isFalse);
    expect(result.message, contains('예산 한도'));
    expect(result.message, contains('Reached maximum budget'));
    expect(result.costUsd, closeTo(0.1055, 0.0001));
    expect(result.needsLogin, isFalse);
  });

  test('정상 끝은 답 글을 그대로 쓴다', () {
    final result = HeadlessResult.fromEvent({
      'type': 'result',
      'subtype': 'success',
      'is_error': false,
      'total_cost_usd': 0.2862134,
      'result': '노트 1개를 초안으로 저장했어요.',
    }, exitCode: 0);
    expect(result.ok, isTrue);
    expect(result.message, '노트 1개를 초안으로 저장했어요.');
  });
}
