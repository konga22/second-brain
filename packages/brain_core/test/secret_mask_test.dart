import 'package:brain_core/brain_core.dart';
import 'package:test/test.dart';

void main() {
  test('알려진 비밀값 형식을 가린다', () {
    const samples = [
      'sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345',
      'ghp_abcdefghijklmnopqrstuvwxyz0123456789',
      'AKIAABCDEFGHIJKLMNOP',
      'sb_secret_abcdefghijklmnop',
      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
    ];
    for (final secret in samples) {
      expect(maskSecrets('키는 $secret 입니다'), '키는 [가림] 입니다', reason: secret);
    }
  });

  test('.env 줄은 이름을 남기고 값만 가린다', () {
    expect(maskSecrets('OPENAI_API_KEY=abcd1234efgh'), 'OPENAI_API_KEY=[가림]');
    expect(
      maskSecrets('export DB_PASSWORD: hunter2hunter'),
      'export DB_PASSWORD: [가림]',
    );
  });

  test('평범한 문장은 그대로 둔다', () {
    const text = '결제 웹훅은 3번까지 재시도한다. KEY 이름만 적힌 줄';
    expect(maskSecrets(text), text);
  });
}
