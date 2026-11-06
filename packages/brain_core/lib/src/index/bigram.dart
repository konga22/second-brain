/// 띄어쓰기를 무시한 2글자 분할 (설계서 4.2).
///
/// - 한글(과 그 밖의 비영문 글자)이 이어지는 구간은 겹치는 2글자로 자른다.
///   한글 사이의 공백 1칸은 무시한다.
/// - 영어·숫자는 단어 그대로 소문자로 둔다.
/// - 문장부호·줄바꿈·그 밖의 기호에서 구간을 끊는다.
/// NFC 정규화는 아직 하지 않는다 (남은작업 문서 참고).
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

  for (final rune in text.toLowerCase().runes) {
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

/// 한 검색어 묶음(공백 없는 덩어리)을 FTS5 식으로 바꾼다.
String? _termExpression(String term) {
  final parts = <String>[];
  for (final [kind, run] in _segments(term)) {
    if (kind == 'w') {
      parts.add('"$run"*');
    } else if (run.runes.length == 1) {
      parts.add('"$run"*');
    } else {
      parts.add('"${_hangulGrams(run).join(' ')}"');
    }
  }
  if (parts.isEmpty) return null;
  return parts.length == 1 ? parts.first : '(${parts.join(' AND ')})';
}

/// 검색어를 FTS5 질의로 바꾼다. 검색할 조각이 없으면 null.
///
/// "결제 실패 원인" → ("결제 제실 실패 패원 원인") OR ("결제" AND "실패" AND "원인")
String? toBigramQuery(String query) {
  final terms = query
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .map(_termExpression)
      .whereType<String>()
      .toList();
  if (terms.isEmpty) return null;
  if (terms.length == 1) return terms.first;
  final joined = _termExpression(query.replaceAll(RegExp(r'\s+'), ''));
  final all = '(${terms.join(' AND ')})';
  return joined == null ? all : '$joined OR $all';
}
