/// 띄어쓰기를 무시한 2글자 분할 (설계서 4.2).
///
/// 1주차 확인용 최소 구현이다. 영문 단어 처리와 NFC 정규화는 2주차에 붙인다.
String toBigrams(String text) {
  final chars = text
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '')
      .runes
      .map(String.fromCharCode)
      .toList();
  if (chars.length < 2) return chars.join();
  return [for (var i = 0; i < chars.length - 1; i++) chars[i] + chars[i + 1]]
      .join(' ');
}

/// 검색어를 FTS5 구문 질의로 바꾼다. 2글자 조각이 이어져 나와야 걸린다.
String toBigramQuery(String query) => '"${toBigrams(query)}"';
