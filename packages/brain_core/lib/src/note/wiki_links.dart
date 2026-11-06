import '../text/nfc.dart';

/// 본문의 `[[제목]]` 링크 대상들 (설계서 4.1). `[[제목|보이는 글]]`, `[[제목#섹션]]`도 읽는다.
/// 코드 블록(```)과 인라인 코드(`…`) 안의 대괄호는 링크로 보지 않는다.
List<String> parseWikiLinks(String body) {
  final withoutCode = body
      .replaceAll(RegExp(r'```[\s\S]*?```'), '')
      .replaceAll(RegExp(r'`[^`\n]*`'), '');
  final targets = <String>[];
  for (final match in RegExp(r'\[\[([^\[\]\n]+?)\]\]').allMatches(withoutCode)) {
    final target = match.group(1)!.split('|').first.split('#').first.trim();
    if (target.isNotEmpty && !targets.contains(target)) targets.add(target);
  }
  return targets;
}

/// 제목·별칭·링크 대상을 비교할 때 쓰는 열쇠: NFC, 앞뒤 공백 제거, 영어 소문자, 연속 공백 1칸.
String linkKey(String name) =>
    toNfc(name).trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
