import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secondbrain/app/theme/app_theme.dart';
import 'package:secondbrain/features/lessons/lessons_page.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// [배운 것]의 "합치기 필요" (설계서_프롬프트이후 4.5): 비슷한 규칙 쌍을 보여 주고 [합치기]가 그 쌍을 넘긴다.
void main() {
  Lesson l(int n, String trigger, String action) => Lesson(
    id: 'L-${n.toString().padLeft(4, '0')}',
    trigger: trigger,
    action: action,
    reason: '시험',
    status: LessonStatus.active,
  );

  testWidgets('적용 중 규칙 32개: 빠지는 수와 비슷한 쌍, [합치기]가 그 쌍을 넘긴다', (tester) async {
    final active = [
      l(1, '커밋하거나 push할 때', '사용자에게 먼저 허락을 받는다'),
      l(2, 'push하기 전에', '사용자 허락을 받는다'),
      for (var n = 3; n <= 32; n++) l(n, 'job$n', 'rule$n'),
    ];
    (Lesson, Lesson)? merged;
    await tester.pumpWidget(
      ShadApp(
        theme: buildAppTheme(Brightness.light),
        home: SingleChildScrollView(
          child: MergeNotice(active: active, isLegacyOrder: false, onMerge: (a, b) => merged = (a, b)),
        ),
      ),
    );
    expect(find.text('합치기 필요'), findsOneWidget);
    expect(find.textContaining('적용 중 규칙이 32개'), findsOneWidget);
    expect(find.textContaining('규칙 2개는 요청과 맞을 때만'), findsOneWidget);
    expect(find.text('L-0001  커밋하거나 push할 때 → 사용자에게 먼저 허락을 받는다'), findsOneWidget);
    expect(find.text('합치기'), findsOneWidget);
    await tester.tap(find.text('합치기'));
    expect({merged!.$1.id, merged!.$2.id}, {'L-0001', 'L-0002'});
  });
}
