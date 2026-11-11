/// 저장 전에 비밀값을 `[가림]`으로 바꾼다 (설계서 5.6).
///
/// 규칙은 테스트(`test/secret_mask_test.dart`)로 확인한다. 2주차에 사례를 늘린다.
final _patterns = <RegExp>[
  RegExp(
    r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
  ),
  RegExp(r'\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{16,}'),
  RegExp(r'\bsb_secret_[A-Za-z0-9_\-]{10,}'),
  RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}'),
  RegExp(r'\bgithub_pat_[A-Za-z0-9_]{20,}'),
  RegExp(r'\bxox[abposr]-[A-Za-z0-9\-]{10,}'),
  RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
  RegExp(r'\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}'),
  // 11/11 검토 K-31에서 더함: Stripe(sk_·rk_ live·test), Google API 키
  RegExp(r'\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}'),
  RegExp(r'\bAIza[0-9A-Za-z_\-]{35}'),
];

/// 값만 가리는 형식: 주소 안 비밀번호(`scheme://사용자:비밀번호@`)와 `Bearer <토큰>`.
final _urlPassword = RegExp(r'(\b[a-z][a-z0-9+.\-]*://[^:/\s@]+:)([^@\s/]+)(@)', caseSensitive: false);
final _bearer = RegExp(r'(\bBearer\s+)([A-Za-z0-9._~+/\-]{16,}=*)', caseSensitive: false);

/// `.env`·JSON·YAML 형식 `이름=값`·`"이름": "값"`: 이름에 KEY·TOKEN·SECRET·PASSWORD가 들어가면 값만 가린다.
/// 이름과 값의 따옴표는 남긴다 (11/11 K-31: JSON 키를 놓쳤다).
final _envPair = RegExp(
  r'''((?:export\s+)?["']?\b([A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Za-z0-9_]*)["']?\s*[=:]\s*["']?)([^\s"',;]+)''',
  caseSensitive: false,
);

String maskSecrets(String text) {
  var masked = text;
  for (final pattern in _patterns) {
    masked = masked.replaceAll(pattern, '[가림]');
  }
  masked = masked
      .replaceAllMapped(_urlPassword, (m) => '${m.group(1)}[가림]${m.group(3)}')
      .replaceAllMapped(_bearer, (m) => '${m.group(1)}[가림]');
  return masked.replaceAllMapped(_envPair, (m) {
    final value = m.group(3)!;
    if (value == '[가림]' || value.length < 4) return m.group(0)!;
    // `max_tokens: 6000`·`token_count: 1500`은 토큰 "수"다. 이 프로젝트 노트에 자주 나온다.
    if (RegExp(r'^\d+$').hasMatch(value) && m.group(2)!.toLowerCase().contains('token')) return m.group(0)!;
    return '${m.group(1)}[가림]';
  });
}

/// JSON으로 보낼 값 안의 모든 글자를 가린다 (목록·맵 안까지). 앱이 경로 B로 서버에 보내기 직전에 쓴다
/// — 질문·노트 제목·요약·규칙·검증할 답이 칸마다 따로 가려지지 않던 것을 한곳에서 막는다 (11/11 K-31·S-6).
Object? maskSecretsDeep(Object? value) => switch (value) {
  String text => maskSecrets(text),
  List<Object?> list => [for (final item in list) maskSecretsDeep(item)],
  Map<Object?, Object?> map => {for (final e in map.entries) e.key: maskSecretsDeep(e.value)},
  _ => value,
};
