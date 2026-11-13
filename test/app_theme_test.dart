import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secondbrain/app/theme/app_theme.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  test('라이트·다크 테마 모두 본문 글꼴이 Pretendard다', () {
    for (final brightness in Brightness.values) {
      final textTheme = buildAppTheme(brightness).textTheme;
      expect(textTheme.family, 'Pretendard');
      expect(textTheme.p.fontFamily, 'Pretendard');
    }
  });

  testWidgets('글꼴을 적지 않은 글(TextStyle(fontSize: 11))도 Pretendard다 — 색은 테마 그대로', (tester) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildAppTheme(Brightness.light),
        builder: (context, child) => withAppFont(child!),
        home: const Text('글꼴 확인', style: TextStyle(fontSize: 11)),
      ),
    );
    final rich = tester.widget<RichText>(find.descendant(of: find.text('글꼴 확인'), matching: find.byType(RichText)));
    expect(rich.text.style!.fontFamily, 'Pretendard');
    expect(rich.text.style!.fontSize, 11);
    expect(rich.text.style!.color, buildAppTheme(Brightness.light).colorScheme.foreground);
  });
}
