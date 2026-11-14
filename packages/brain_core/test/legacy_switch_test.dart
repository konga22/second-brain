import 'package:brain_core/brain_core.dart';
import 'package:test/test.dart';

/// "이전 방식" 스위치 (설계서_프롬프트이후 7.3): 바뀐 동작을 항목별로 v1으로 되돌린다.
void main() {
  test('환경변수가 없으면 설정 값을 쓴다', () {
    expect(AppConfig.legacyItems(null, {'drafts'}), {'drafts'});
  });

  test('환경변수가 있으면 설정보다 먼저 본다 (빈 값 = 모두 새 방식)', () {
    expect(AppConfig.legacyItems('lessons, drafts', {'folders'}), {'lessons', 'drafts'});
    expect(AppConfig.legacyItems('', {'drafts'}), isEmpty);
  });

}
