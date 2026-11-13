import '../lessons/lesson_store.dart';
import '../text/nfc.dart';
import 'search_index.dart';

/// 찾은 노트가 질문과 "확실히" 맞는가: 질문의 단어 머리가 제목·요약·태그에 2개 이상 들어 있다
/// (질문 단어가 하나뿐이면 1개). 2글자 조각 검색은 조각 하나만 맞아도 결과를 채우므로,
/// 이 표시로 AI가 약한 후보를 열지 않게 한다 (11/07 비교: 답 없는 질문 6개를 모두 "확실한 노트 없음"으로).
/// 찾기 결과에 남길 만큼은 맞는가: 질문 단어 머리가 제목·요약·태그·**본문**에 2개 이상 (단어가 하나면 1개).
/// [isStrongMatch]보다 느슨하다. 규칙 비교(11/07, tool/strong_rules.dart): 정답 남김 17/20, 답 없음 맞힘 4/6.
bool isRelevantMatch(String query, IndexedDoc doc, String body) {
  final heads = LessonStore.wordHeads(query);
  if (heads.isEmpty) {
    // 한 글자 낱말뿐인 질문(`훅`, `맥`)은 단어 머리(2글자)가 없어 늘 "확실한 노트 없음"이었다 (11/11 K-28).
    // 그 글자가 제목·요약·태그에 있으면 남긴다. 본문은 보지 않는다(한 글자는 본문 어디에나 섞여 있다).
    final words = [
      for (final w in toNfc(query).toLowerCase().split(RegExp(r'[\s?？!.,]+')))
        if (w.isNotEmpty) w,
    ];
    if (words.isEmpty) return false;
    final head = toNfc('${doc.title} ${doc.summary} ${doc.tags}').toLowerCase();
    return words.every(head.contains);
  }
  final text = toNfc('${doc.title} ${doc.summary} ${doc.tags} $body').toLowerCase();
  final matched = heads.where(text.contains).length;
  return matched >= 2 || heads.length == 1 && matched == 1;
}

bool isStrongMatch(String query, IndexedDoc doc, {Set<String> ignore = const {}}) {
  final heads = LessonStore.wordHeads(query).where((h) => !ignore.contains(h)).toList();
  if (heads.isEmpty) return false;
  final text = toNfc('${doc.title} ${doc.summary} ${doc.tags}').toLowerCase();
  final matched = heads.where(text.contains).length;
  return matched >= 2 || heads.length == 1 && matched == 1;
}
