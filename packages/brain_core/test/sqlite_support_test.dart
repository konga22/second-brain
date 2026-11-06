import 'package:brain_core/brain_core.dart';
import 'package:test/test.dart';

void main() {
  test('묶어 온 SQLite에서 FTS5·contentless_delete·2글자 검색이 된다', () {
    final support = checkSqliteSupport();
    expect(support.error, isNull);
    expect(support.hasFts5, isTrue);
    expect(support.hasContentlessDelete, isTrue);
    expect(support.bigramSearchWorks, isTrue);
  });

  test('띄어쓰기와 문장부호를 무시하고 2글자씩 나눈다', () {
    expect(toBigrams('결제 오류!'), '결제 제오 오류');
    expect(toBigrams('가'), '가');
  });
}
