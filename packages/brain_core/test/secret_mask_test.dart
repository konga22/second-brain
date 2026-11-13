import 'dart:convert';

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

  // 11/11 검토 K-31: 흔한 형식을 놓쳤다. 노트·대화에 실제로 붙여 넣는 모양으로 적는다.
  const mustMask = {
    'JSON 키': ('설정 파일은 {"api_key": "a1b2c3d4e5f6g7h8"} 이렇게 생겼다', 'a1b2c3d4e5f6g7h8'),
    'YAML 따옴표': ("client_secret: 'Zx9Yw8Vu7Ts6Rq5P'", 'Zx9Yw8Vu7Ts6Rq5P'),
    'DB 주소 비밀번호': ('DATABASE_URL 대신 postgres://admin:S3cr3tPass@db.example.com:5432/app 로 붙었다', 'S3cr3tPass'),
    'Bearer 헤더': ('curl -H "Authorization: Bearer abcDEF123456ghiJKL789" 로 불렀더니 401', 'abcDEF123456ghiJKL789'),
    'Stripe 키': ('결제 시험은 sk_test_51HxYzAbCdEfGhIjKlMn 로 했다', 'sk_test_51HxYzAbCdEfGhIjKlMn'),
    'Stripe 운영 키': ('rk_live_9aBcDeFgHiJkLmNoPq12 는 서버에만', 'rk_live_9aBcDeFgHiJkLmNoPq12'),
    'Google API 키': ('지도 키 AIzaSyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q 를 넣었다', 'AIzaSyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q'),
  };
  const mustKeep = [
    '로컬 DB는 postgres://localhost:5432/app 에 있다',
    'Bearer 토큰을 헤더에 넣으면 된다',
    'sk_live_ 로 시작하는 키는 서버 환경변수에만 둔다',
    'max_tokens: 6000 으로 올렸더니 잘림이 없어졌다',
    '{"token_count": 1500, "model": "haiku"}',
    'API 키는 Supabase Edge Functions 환경변수에만 둔다',
    'https://user@github.com/konga22/second-brain.git 로 받았다',
  ];

  test('흔한 비밀값 형식 (K-31) — 가려야 할 것', () {
    final missed = [
      for (final MapEntry(key: name, value: (text, secret)) in mustMask.entries)
        if (maskSecrets(text).contains(secret)) name,
    ];
    expect(missed, isEmpty, reason: '못 가림 ${missed.length}/${mustMask.length}: $missed');
  });

  test('흔한 비밀값 형식 (K-31) — 가리면 안 되는 것', () {
    final wrong = [for (final text in mustKeep) if (maskSecrets(text) != text) '$text → ${maskSecrets(text)}'];
    expect(wrong, isEmpty, reason: '잘못 가림 ${wrong.length}/${mustKeep.length}: $wrong');
  });

  test('보낼 JSON 안의 모든 글자를 가린다 (경로 B)', () {
    final body = {
      'task': 'answer',
      'question': '이 키 sk-ant-api03-abcdefghijklmnopqrstuvwxyz 왜 안 돼?',
      'notes': [
        {'id': 'n_0001', 'title': '배포 키 ghp_abcdefghijklmnopqrstuvwxyz0123456789', 'tokens': 120},
      ],
      'lessons': [
        {'trigger': '설정할 때', 'action': 'API_KEY=abcd1234efgh 는 넣지 않는다'},
      ],
    };
    final masked = jsonEncode(maskSecretsDeep(body));
    expect(masked, isNot(contains('sk-ant-api03')));
    expect(masked, isNot(contains('ghp_')));
    expect(masked, isNot(contains('abcd1234efgh')));
    expect(masked, contains('"tokens":120'));
    expect(masked, contains('"task":"answer"'));
  });
}
