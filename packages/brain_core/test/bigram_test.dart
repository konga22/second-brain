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
    expect(toBigramQuery('JWT키'), '("jwt"* AND "키"*)');
    expect(toBigramQuery('  !! '), isNull);
  });

  // 11/08 검색 시험(docs/검색시험.md)에서 놓친 질문들
  test('개발 용어는 한글·영어 표기를 함께 찾는다', () {
    expect(toBigramQuery('엑스코드'), '("엑스 스코 코드" OR "xcode"*)');
    expect(toBigramQuery('스위프트를'), contains('"swift"*'));
    expect(toBigramQuery('Flutter'), '("flutter"* OR "플러 러터")');
    expect(toBigramQuery('API키'), '(("api"* OR "에이 이피 피아 아이") AND "키"*)');
  });

  test('묻는 말은 검색어에서 빼고, 그것만 남으면 그대로 둔다', () {
    expect(toRelaxedQuery('역설계할 때 쓰던 도구 이름이 뭐였지?'), isNot(contains('쓰던')));
    expect(toRelaxedQuery('역설계할 때 쓰던 도구 이름이 뭐였지?'), isNot(contains('이름')));
    expect(toBigramQuery('뭐였지?'), isNotNull);
    expect(toBigramQuery('엑스코드 꼭 설치해야 해?'), isNot(contains('"꼭"')));
  });
}
