import 'package:brain_core/brain_core.dart';
import 'package:test/test.dart';

/// 저장할 때 상태 문장 알림 (설계서_프롬프트이후 5.10 ③, 11/14). 7번 지식 품질 감사의 단어 규칙.
void main() {
  test('상태 문장을 문장 단위로 뽑는다 (목록 머리·코드 블록·머리말은 뺀다)', () {
    const body = '''
## 남은 것
- 결제 웹훅은 3번까지 다시 보낸다. 실제 운영에서는 아직 안 돌렸다.
- 남은 것: 화면 넘침 1건(어느 화면인지 모름)
```
// 아직 코드 속 주석
```
배포 전 확인은 끝났다? 다음 주 발표 예정.
''';
    expect(statusSentences(body, limit: 10), [
      '실제 운영에서는 아직 안 돌렸다.',
      '남은 것: 화면 넘침 1건(어느 화면인지 모름)',
      '배포 전 확인은 끝났다?',
      '다음 주 발표 예정.',
    ]);
  });

  test('상태 단어가 없으면 알림이 없다 (확정된 것만 적은 노트)', () {
    expect(statusSentences('결제 웹훅은 3번까지 다시 보낸다.\n11/12에 실제 운영에서 확인했다.'), isEmpty);
    expect(statusSentenceHint('n_0001', summary: '웹훅 3번', body: '3번까지 다시 보낸다.'), isNull);
  });

  test('알림에는 문장과 할 일로 보내는 명령이 들어가고, 긴 문장은 자른다', () {
    final hint = statusSentenceHint('n_0042', summary: '조사만, 구현은 미정', body: '${'가' * 100} 아직 안 함');
    expect(hint, contains('상태 문장 2개'));
    expect(hint, contains('"조사만, 구현은 미정"'));
    expect(hint, contains('…"'));
    expect(hint, contains('brain todo suggest "<할 일>" --source n_0042'));
  });

  test('감사에서 상태 문장이 원인이던 말투를 잡는다 (사용자 말투로 바꾼 입력, L-0008)', () {
    final caught = [
      '실제 dontAsk 세션에서 우회 입력이 거부되는지는 아직 안 돌렸다.',
      '후보(아직): fastforge로 .dmg 만들기',
      '실수 노트 L-0012(승인 대기)',
      '사용 중(배포 전): Anthropic TS SDK',
      '해결 방향: 안내에서 세션 id를 뺀다.',
      '남음: 할 일 후보에 summary 줄이 들어간다',
      '발표일은 미정이라 표지에 대회명을 넣음',
    ];
    final ignored = [
      '11/12 실제 claude -p에서 우회 입력 7개가 거부되는 것까지 확인했다.',
      '11/12 tool/make_dmg.sh로 .dmg를 직접 만들었다.',
      '실수 노트 L-0012(적용 중)',
      'busy_timeout 5000, WAL 설정보다 먼저 건다.',
    ];
    expect([for (final s in caught) if (statusSentences(s).isNotEmpty) s], caught);
    expect([for (final s in ignored) if (statusSentences(s).isNotEmpty) s], isEmpty);
  });
}
