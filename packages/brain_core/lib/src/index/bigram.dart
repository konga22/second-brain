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

/// 한 검색어 묶음(공백 없는 덩어리)을 FTS5 식으로 바꾼다.
String? _termExpression(String term) {
  final parts = <String>[];
  for (final [kind, run] in _segments(term)) {
    parts.add(kind == 'w' ? '"$run"*' : _hangulExpression(run));
  }
  if (parts.isEmpty) return null;
  return parts.length == 1 ? parts.first : '(${parts.join(' AND ')})';
}

List<String> _terms(String query) => toNfc(query)
    .split(RegExp(r'\s+'))
    .where((t) => t.isNotEmpty)
    .toList();

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
