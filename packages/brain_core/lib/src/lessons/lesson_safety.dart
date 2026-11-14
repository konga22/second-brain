import '../lint/linter.dart';
import '../text/nfc.dart';
import 'lesson_store.dart';
import '../security/secret_mask.dart';

/// 실수 노트를 "적용 중"으로 만들기 전 안전 검사 (설계서 5.4 v1.3.35, 11/12 사용자 결정 "안전하다 검증되는 즉시 적용").
///
/// 적용 중 규칙은 모든 Claude Code 세션 시작에 들어간다. AI가 노트·웹 글 속 숨은 지시에 속아 규칙을 만들면
/// 영구 주입이 되므로(독립 검토 K-19(나)·S-5), 내용에 아래가 있으면 승인 대기로 둔다. 걸린 까닭을 돌려준다.
List<String> lessonSafetyProblems({
  required String trigger,
  required String action,
  required String reason,
}) {
  final text = '$trigger\n$action\n$reason';
  final problems = <String>[];
  if (Linter.suspiciousPattern.hasMatch(text)) problems.add('숨은 지시처럼 보이는 문장');
  if (_url.hasMatch(text)) problems.add('외부 주소(URL)');
  if (_command.hasMatch(text)) problems.add('위험한 명령');
  if (_sendSecret.hasMatch(text)) problems.add('비밀값을 보내거나 적으라는 말');
  if (_bypass.hasMatch(text)) problems.add('검사·허락을 끄거나 건너뛰라는 말');
  if (maskSecrets(text) != text) problems.add('비밀값으로 보이는 값');
  return problems;
}

/// 근거 검사: [quote](사용자가 한 말)가 [userTexts](지금 세션의 사용자 발화) 안에 그대로 있는가.
/// 공백·문장부호는 빼고 비교하고, 짧은 말(8자 미만)은 우연히 맞을 수 있어 근거로 보지 않는다.
bool isQuoteFromUser(String quote, Iterable<String> userTexts) {
  final wanted = _plain(quote);
  if (wanted.runes.length < 8) return false;
  return userTexts.any((t) => _plain(t).contains(wanted));
}

/// 관련 검사: [quote](근거로 댄 사용자 말)와 [ruleText](규칙의 언제·무엇을·왜·diff)가 낱말 머리를 하나 이상 함께 쓰는가.
/// 근거 검사는 "그 말이 세션에 있는가"만 봐서, 규칙과 관계없는 말("오늘 회의록 정리도 부탁해")을 대도 바로 적용됐다
/// (보안 감사 11/14). 지난 교정 27건을 그 교정에서 생긴 실수 노트와 견주면 24건이 이 기준을 지나고, 못 지나는 3건은
/// 승인 대기로 남는다(사라지지 않는다). AI가 규칙 문장을 근거 말에 맞춰 지으면 지나간다 — 막는 것은 관계없는 말을 그대로 댄 경우다.
bool isQuoteRelated(String quote, String ruleText) {
  final rule = toNfc(ruleText).toLowerCase();
  return LessonStore.wordHeads(quote).any(rule.contains);
}

String _plain(String text) => text.toLowerCase().replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');

final _url = RegExp(r'https?://|www\.[a-z0-9-]+\.[a-z]', caseSensitive: false);

final _command = RegExp(
  r'rm\s+-[a-z]*[rf]|\bcurl\s|\bwget\s|\bsudo\s|\bchmod\s|\bscp\s|\bssh\s+\S+@|\|\s*(ba|z)?sh\b|>\s*/dev/|\bmkfs|\bdd\s+if=',
  caseSensitive: false,
);

final _sendSecret = RegExp(
  r'(api\s*키|api\s*key|토큰|token|비밀번호|password|비밀값|secret|인증\s*정보|키\s*파일|\.env|ssh\s*키)'
  r'[^\n]{0,30}(보내|전송|올려|올리|업로드|공유|붙여|적어|출력|알려|첨부|send|upload|post|print)',
  caseSensitive: false,
);

final _bypass = RegExp(
  r'(허락|승인|확인|검사|검증|테스트|시험|리뷰)\s*(없이|[을를]?\s*받지\s*않|하지\s*않고|[을를]?\s*건너뛰|[을를]?\s*생략)'
  r'|(훅|hook|검사|검증|실수\s*노트|규칙|보안)[^\n]{0,15}(끄|꺼|끈다|비활성|무시|우회|지우|삭제)'
  r'|--no-verify|--force\s+push|push\s+--force|묻지\s*(말고|않고)',
  caseSensitive: false,
);
