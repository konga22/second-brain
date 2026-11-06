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
];

/// `.env` 형식 `이름=값`: 이름에 KEY·TOKEN·SECRET·PASSWORD가 들어가면 값만 가린다.
final _envPair = RegExp(
  r'((?:export\s+)?\b[A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Za-z0-9_]*\s*[=:]\s*)(\S+)',
  caseSensitive: false,
);

String maskSecrets(String text) {
  var masked = text;
  for (final pattern in _patterns) {
    masked = masked.replaceAll(pattern, '[가림]');
  }
  return masked.replaceAllMapped(_envPair, (m) {
    final value = m.group(2)!;
    if (value == '[가림]' || value.length < 4) return m.group(0)!;
    return '${m.group(1)}[가림]';
  });
}
