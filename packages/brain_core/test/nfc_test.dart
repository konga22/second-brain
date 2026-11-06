import 'package:brain_core/brain_core.dart';
import 'package:test/test.dart';

void main() {
  test('풀어 쓴 한글(NFD)을 완성형(NFC)으로 합친다', () {
    // "결제 오류"를 자모로 풀어 쓴 것: ㄱ ㅕ ㄹ ㅈ ㅔ 공백 ㅇ ㅗ ㄹ ㅠ
    const nfd = '결제 오류';
    expect(toNfc(nfd), '결제 오류');
  });

  test('이미 완성형이거나 영어면 그대로 둔다', () {
    expect(toNfc('결제 오류 API키'), '결제 오류 API키');
    expect(identical(toNfc('abc'), 'abc'), isTrue);
  });

  test('NFD 제목도 NFC 검색어로 2글자 분할이 같다', () {
    const nfd = '결제';
    expect(toBigrams(nfd), toBigrams('결제'));
    expect(toBigramQuery(nfd), toBigramQuery('결제'));
  });
}
