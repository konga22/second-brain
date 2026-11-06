import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secondbrain/app/theme/app_theme.dart';

void main() {
  test('라이트·다크 테마 모두 본문 글꼴이 Pretendard다', () {
    for (final brightness in Brightness.values) {
      final textTheme = buildAppTheme(brightness).textTheme;
      expect(textTheme.family, 'Pretendard');
      expect(textTheme.p.fontFamily, 'Pretendard');
    }
  });
}
