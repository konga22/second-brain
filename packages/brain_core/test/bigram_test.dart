import 'package:brain_core/brain_core.dart';
import 'package:test/test.dart';

void main() {
  test('한글 사이 공백 1칸은 무시하고 2글자씩 나눈다', () {
    expect(toBigrams('결제 웹훅을 다시 보낸다'), '결제 제웹 웹훅 훅을 을다 다시 시보 보낸 낸다');
  });

  test('영어·숫자는 단어 그대로 소문자', () {
    expect(toBigrams('API키 v2 오류'), 'api 키 v2 오류');
  });

  test('검색어: 여러 단어면 이어 붙인 구절 OR 단어별 AND', () {
    expect(toBigramQuery('결제 실패'), '"결제 제실 실패" OR ("결제" AND "실패")');
    expect(toBigramQuery('책'), '"책"*');
    expect(toBigramQuery('API키'), '("api"* AND "키"*)');
    expect(toBigramQuery('  !! '), isNull);
  });
}
