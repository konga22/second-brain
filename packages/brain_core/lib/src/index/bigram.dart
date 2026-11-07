import '../text/nfc.dart';

/// 띄어쓰기를 무시한 2글자 분할 (설계서 4.2).
///
/// - 한글(과 그 밖의 비영문 글자)이 이어지는 구간은 겹치는 2글자로 자른다.
///   한글 사이의 공백 1칸은 무시한다.
/// - 영어·숫자는 단어 그대로 소문자로 둔다.
/// - 문장부호·줄바꿈·그 밖의 기호에서 구간을 끊는다.
/// 자르기 전에 NFC로 맞춘다 ([toNfc]).
List<List<String>> _segments(String text) {
  final segments = <List<String>>[];
  final buffer = StringBuffer();
  String? kind; // 'h' = 한글 등, 'w' = 영문·숫자
  var pendingSpace = false;

  void flush() {
    if (buffer.isEmpty) return;
    segments.add([kind!, buffer.toString()]);
    buffer.clear();
    kind = null;
  }

  for (final rune in toNfc(text).toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    final isAsciiWord =
        (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x61 && rune <= 0x7a) ||
        rune == 0x5f;
    final isLetter =
        !isAsciiWord &&
        rune > 0x7f &&
        RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(char);
    if (char == ' ' && kind == 'h' && !pendingSpace) {
      pendingSpace = true;
      continue;
    }
    final next = isAsciiWord ? 'w' : (isLetter ? 'h' : null);
    if (next == null) {
      flush();
      pendingSpace = false;
      continue;
    }
    if (kind != next || (pendingSpace && next != 'h')) flush();
    pendingSpace = false;
    kind = next;
    buffer.write(char);
  }
  flush();
  return segments;
}

List<String> _hangulGrams(String run) {
  final chars = run.runes.map(String.fromCharCode).toList();
  if (chars.length < 2) return chars;
  return [for (var i = 0; i < chars.length - 1; i++) chars[i] + chars[i + 1]];
}

/// 저장용: 색인에 넣을 조각 문자열.
String toBigrams(String text) => [
  for (final [kind, run] in _segments(text))
    if (kind == 'h') ..._hangulGrams(run) else run,
].join(' ');

// 검색어 끝에 붙는 조사·어미. 떼어 낸 형태도 함께 찾는다 ("웹훅이" → "웹훅").
// 형태소 분석기 대신 쓰는 단순 규칙이라, 남는 말이 2글자 이상일 때만 뗀다.
const _endings = [
  '에서는', '으로는', '이라는', '에서', '으로', '에게', '까지', '부터', '처럼', '보다',
  '하면', '하는', '하고', '해서', '했다', '한다', '이다', '이나', '이랑', '에는', '에도',
  '으면', '는데', '지만', '라는', '려면', '이', '가', '을', '를', '은', '는', '에', '도',
  '로', '의', '와', '과', '만', '면', '고',
];

/// 한글 덩어리의 찾을 형태들: 원래 형태 + 조사·어미를 뗀 형태.
List<String> _stems(String run) {
  final forms = [run];
  for (final ending in _endings) {
    if (run.endsWith(ending) && run.runes.length - ending.runes.length >= 2) {
      final stem = String.fromCharCodes(
        run.runes.take(run.runes.length - ending.runes.length),
      );
      if (!forms.contains(stem)) forms.add(stem);
    }
  }
  return forms;
}

String _hangulExpression(String run) {
  final forms = [
    for (final form in _stems(run))
      if (form.runes.length == 1) '"$form"*' else '"${_hangulGrams(form).join(' ')}"',
  ];
  return forms.length == 1 ? forms.first : '(${forms.join(' OR ')})';
}

// 개발 용어의 한글·영어 표기 (11/08 검색 시험: "스위프트"·"엑스코드"로 물으면 노트의 "Swift"·"Xcode"를 못 찾음).
// 한글로 물으면 영어 표기도, 영어로 물으면 한글 표기도 함께 찾는다. 설계서 4.2 "표기 차이는 aliases로"의 기본 사전.
const _spellings = {
  '스위프트': 'swift', '엑스코드': 'xcode', '플러터': 'flutter', '다트': 'dart', '깃허브': 'github',
  '깃': 'git', '도커': 'docker', '파이썬': 'python', '자바스크립트': 'javascript', '타입스크립트': 'typescript',
  '리액트': 'react', '노드': 'node', '클로드': 'claude', '코덱스': 'codex', '수파베이스': 'supabase',
  '아이폰': 'iphone', '맥북': 'macbook', '맥': 'mac', '윈도우': 'windows', '리눅스': 'linux',
  '안드로이드': 'android', '쿠버네티스': 'kubernetes', '버셀': 'vercel', '노션': 'notion', '옵시디언': 'obsidian',
  '디스코드': 'discord', '슬랙': 'slack', '크롬': 'chrome', '사파리': 'safari', '터미널': 'terminal',
  '플러그인': 'plugin', '스킬': 'skill', '훅': 'hook', '세션': 'session', '웹훅': 'webhook',
  '아이솔레이트': 'isolate', '토큰': 'token', '프롬프트': 'prompt', '에이전트': 'agent', '리버팟': 'riverpod',
  '아스트로': 'astro', '테일윈드': 'tailwind', '파이어베이스': 'firebase', '에스큐엘라이트': 'sqlite', '마크다운': 'markdown',
  '테라폼': 'terraform', '에이더블유에스': 'aws', '카카오톡': 'kakaotalk', '제이슨': 'json', '유에스비': 'usb',
  '에이피아이': 'api', '시엘아이': 'cli', '깃랩': 'gitlab', '코틀린': 'kotlin', '자바': 'java',
  '러스트': 'rust', '고랭': 'golang', '피그마': 'figma', '슈퍼베이스': 'supabase', '엠씨피': 'mcp',
};
final _reverseSpellings = {for (final e in _spellings.entries) e.value: e.key};

/// 한 검색어 묶음(공백 없는 덩어리)을 FTS5 식으로 바꾼다.
String? _termExpression(String term) {
  final parts = <String>[];
  for (final [kind, run] in _segments(term)) {
    if (kind == 'w') {
      final korean = _reverseSpellings[run];
      // 사전의 한글 표기는 그대로 찾는다 (조사 떼기를 하면 "에이피아이" → "에이피아"처럼 잘린다).
      parts.add(korean == null ? '"$run"*' : '("$run"* OR "${_hangulGrams(korean).join(' ')}")');
    } else {
      final english = [for (final form in _stems(run)) ?_spellings[form]].firstOrNull;
      final expr = _hangulExpression(run);
      parts.add(english == null ? expr : '($expr OR "$english"*)');
    }
  }
  if (parts.isEmpty) return null;
  return parts.length == 1 ? parts.first : '(${parts.join(' AND ')})';
}

// 묻는 말·채움말. 검색어에서 뺀다 (11/08 검색 시험: "역설계할 때 쓰던 도구 이름이 뭐였지?"에서 "쓰던·이름이·뭐였지"가
// 느슨한 검색에서 다른 노트를 끌어올려 정답이 7위). 이것만 남으면 빼지 않는다.
const _questionWords = {
  '뭐', '뭐야', '뭐지', '뭐였지', '뭐였더라', '뭐더라', '뭔지', '뭐가', '무엇', '무엇을', '무슨', '어떻게', '어떤', '어디',
  '어디에', '언제', '왜', '누가', '했지', '했었지', '했어', '했나', '했더라', '했던', '하던', '쓰던', '있어', '있나',
  '있었지', '있을까', '있었나', '이름', '이름이', '알려', '알려줘', '줘', '거', '것', '거야', '건', '좀', '꼭', '해',
  '해야', '해야해', '해줘', '되나', '돼', '될까', '그거', '그', '이거', '정리한', '적어', '둔',
};

List<String> _terms(String query) {
  final all = toNfc(query)
      .replaceAll(RegExp(r'[?？!.]'), ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  final kept = [for (final t in all) if (!_questionWords.contains(t)) t];
  return kept.isEmpty ? all : kept;
}

/// 검색어를 FTS5 질의로 바꾼다. 검색할 조각이 없으면 null.
///
/// "결제 실패 원인" → ("결제 제실 실패 패원 원인") OR ("결제" AND "실패" AND "원인")
String? toBigramQuery(String query) {
  final terms = _terms(query).map(_termExpression).whereType<String>().toList();
  if (terms.isEmpty) return null;
  if (terms.length == 1) return terms.first;
  final joined = _termExpression(_terms(query).join());
  final all = '(${terms.join(' AND ')})';
  return joined == null ? all : '$joined OR $all';
}

/// 느슨한 질의: 검색어 중 하나라도 맞으면 찾는다. 엄격한 결과가 모자랄 때 채운다.
String? toRelaxedQuery(String query) {
  final terms = _terms(query).map(_termExpression).whereType<String>().toList();
  if (terms.length < 2) return null;
  return terms.join(' OR ');
}
