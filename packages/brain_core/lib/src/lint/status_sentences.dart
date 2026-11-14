/// 저장할 때 상태 문장 알림 (설계서_프롬프트이후 5.10 ③, 11/14).
///
/// "아직·남은 것·예정·후보·승인 대기·배포 전·미정·미룸"이 든 문장은 그 일이 끝나면 노트를 낡게 만든다.
/// 7번 지식 품질 감사(11/14)에서 낡은 노트 32개 가운데 14개의 원인이 이런 상태 문장이었고, `brain lint`는 0개를 봤다.
/// 같은 단어 규칙이 32개 중 17개를 잡고 걸린 것의 60%가 맞았다 — 그래서 막지 않고 한 줄 알리기만 한다.
library;

/// 상태 단어. 감사에서 잰 규칙에 `해결 방향`(감사의 상태 문장 원인에 있던 말)을 더했다. 단어를 늘리면 헛알림도 는다.
/// `남음`은 `남은 것`의 다른 꼴.
final _statusWord = RegExp(r'아직|남은 것|남음|예정|후보|승인 대기|배포 전|미정|미룸|해결 방향');

/// [text]에서 상태 단어가 든 문장. 줄 → 문장(`. `·`? `·`! `)으로 나누고, 코드 블록·머리말 줄은 건너뛴다.
/// 같은 문장은 한 번만, 앞에서부터 [limit]개, 문장마다 [maxLength]자에서 자른다.
List<String> statusSentences(String text, {int limit = 3, int maxLength = 70}) {
  final found = <String>[];
  var inCode = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('```')) {
      inCode = !inCode;
      continue;
    }
    if (inCode || line.isEmpty || line.startsWith('#')) continue;
    for (final part in line.split(RegExp(r'(?<=[.?!])\s+'))) {
      final sentence = part.replaceFirst(RegExp(r'^[-*>]+\s*'), '').trim();
      if (sentence.isEmpty || !_statusWord.hasMatch(sentence)) continue;
      final clipped = sentence.length <= maxLength ? sentence : '${sentence.substring(0, maxLength)}…';
      if (!found.contains(clipped)) found.add(clipped);
      if (found.length >= limit) return found;
    }
  }
  return found;
}

/// `brain add`·`brain write` 뒤에 붙이는 알림 한 덩어리. 상태 문장이 없으면 null.
String? statusSentenceHint(String id, {required String summary, required String body}) {
  final found = statusSentences('$summary\n$body');
  if (found.isEmpty) return null;
  return [
    '상태 문장 ${found.length}개 — 그 일이 끝나면 이 노트가 낡는다 (확정된 것만 노트에, 할 일은 할 일로):',
    for (final s in found) '  · "$s"',
    '  할 일이면 brain todo suggest "<할 일>" --source $id 로 보내고, 노트에서는 빼거나 "언제 기준"을 붙인다(brain write).',
  ].join('\n');
}
