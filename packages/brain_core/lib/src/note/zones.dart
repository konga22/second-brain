import '../text/nfc.dart';
import 'file_name.dart';
import 'note_store.dart' show NoteStoreException;

/// 지식 폴더 구조: 고정 구역 + 주제 (설계서_프롬프트이후 5.1). 경로는 `wiki/<구역>/<주제>/<파일>.md`.
///
/// 구역은 사용자만 만들고 바꾼다 — AI가 구역을 지으면 주제가 들쭉날쭉해진 문제(B6)가 구역에서 다시 생긴다.
/// 지금은 다섯 개로 고정한다. 구역 이름 목록이 코드에 있어 색인의 경로 읽기([IndexedDoc.zone])가 파일을 보지 않는다.
const noteZones = ['프로젝트', '개발 지식', '조사·참고', '공부', '생활·기기'];

/// 자리 규칙 한 줄 (설계서_프롬프트이후 3.3). 거절 안내와 `brain topics`가 같은 글을 쓴다.
const zonePlacementRule =
    '자리 규칙: 다른 프로젝트에서도 다시 쓸 지식은 개발 지식/<기술>, 그 프로젝트에서만 뜻이 있으면 프로젝트/<이름>, '
    '찾아본 자료·레포는 조사·참고, 수업·학습은 공부, 기기·생활은 생활·기기.';

/// 한 주제의 노트가 이보다 많으면 앱이 나누자고 제안한다 (설계서_프롬프트이후 5.1).
const topicSplitLimit = 30;

bool isZone(String name) => noteZones.contains(toNfc(name.trim()));

/// AI가 모르는 구역(또는 구역 없이)으로 저장·옮기려 했다. 구역 목록과 주제를 보여 주고 거절한다.
class UnknownZoneException extends NoteStoreException {
  const UnknownZoneException(super.message);
}

/// 제목에서 짧은 파일 이름을 만든다 (설계서_프롬프트이후 5.1: 20자 안팎, 특수문자 없이). 긴 제목은 파일 안에 둔다.
///
/// 파일 이름이 길면 Finder·사이드바에서 훑어보기 어렵고(11/13 30자 넘는 이름 86개 중 37개), 링크는 제목으로 잇기 때문에
/// 이름을 줄여도 `[[제목]]`이 깨지지 않는다.
/// 1. 구분 기호(` — `, `- `, `: `, ` (`) 앞이 4자 이상이면 그 앞까지
/// 2. 글자·숫자·띄어쓰기만 남긴다 (`·`·`.`·`_` 등은 띄어쓰기로)
/// 3. [max]자를 넘으면 낱말 경계에서 자른다
String shortNoteName(String title, {int max = 20}) {
  var text = toNfc(title).trim();
  for (final separator in [' — ', ' – ', '- ', ': ', ' (', '(']) {
    final at = text.indexOf(separator);
    if (at >= 0 && text.substring(0, at).trim().runes.length >= 4) text = text.substring(0, at);
  }
  text = text.replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ').replaceAll(RegExp(r' +'), ' ').trim();
  final runes = text.runes.toList();
  if (runes.length > max) {
    final cut = String.fromCharCodes(runes.take(max));
    final space = cut.lastIndexOf(' ');
    // 자른 자리가 마침 낱말 끝이면 그대로, 아니면 앞 낱말 경계까지 (반쪽 낱말을 남기지 않게)
    final atBoundary = runes[max] == 0x20;
    text = (atBoundary || space < cut.length ~/ 2 ? cut : cut.substring(0, space)).trim();
    // 잘린 이름 끝의 한 글자 낱말과 이음 조사(과·와)를 뗀다: "레포와 안" → "레포", "원인과" → "원인"
    final words = text.split(' ');
    if (words.length > 2 && words.last.runes.length == 1) words.removeLast();
    final last = words.last;
    if (words.length > 1 && last.runes.length > 2 && (last.endsWith('과') || last.endsWith('와'))) {
      words[words.length - 1] = last.substring(0, last.length - 1);
    }
    text = words.join(' ');
  }
  if (text.isEmpty) text = '노트';
  if (text.toLowerCase() == 'index') text = '$text 노트';
  return text;
}

/// 주제 이름 비교용 열쇠: 대소문자·띄어쓰기·문장부호를 뺀다 (설계서_프롬프트이후 5.1-4, 11/13 검토).
/// `ClaudeCode`·`Claude Code`·`claude-code`가 같은 주제로 갈리지 않게 한다 — 주제가 들쭉날쭉한 문제(B6)가 이름 모양에서 다시 생겼다.
String topicKey(String name) => toNfc(name).toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// [topics] 중 [name]과 같은 주제 (글자가 똑같은 것 먼저, 없으면 [topicKey]가 같은 것).
String? sameTopic(String name, List<String> topics) {
  final key = topicKey(name);
  if (key.isEmpty) return null;
  return topics.where((t) => t == name).firstOrNull ?? topics.where((t) => topicKey(t) == key).firstOrNull;
}

/// 이전 방식(구역 없음, `BRAIN_LEGACY=folders`)에서 새 노트의 `--topic` 값 → 주제 폴더 이름 (설계서_프롬프트이후 5.1, 11/13 검토).
///
/// `구역/주제`면 구역을 떼고 주제만 쓴다: 스킬·세션 안내는 방식을 몰라 늘 `구역/주제`로 주는데, 예전에는 빗금이 `-`로 바뀌어
/// `wiki/프로젝트-쇼핑몰/` 같은 폴더가 생겼다. 이전 방식은 "새 노트를 예전처럼 `wiki/<주제>/<제목>.md`에" 두는 스위치라 구역 폴더를
/// 만들지 않는다. 사람이 고른 옮기기·주제 만들기([NoteStore.move]·[NoteStore.createTopic])는 이전 방식에서도 `구역/주제`를
/// 그대로 따른다 — 그때는 사용자가 구역을 직접 고른 것이다. 구역이 아닌 이름의 빗금(`a/b`)은 예전처럼 둔다.
String? legacyTopicName(String? topic) {
  if (topic == null) return null;
  final parts = [for (final part in toNfc(topic.trim()).split('/')) part.trim()];
  if (parts.length == 2 && isZone(parts[0]) && parts[1].isNotEmpty) return parts[1];
  return topic;
}

/// `--topic` 값을 지식 폴더 안 주제 경로(`구역/주제`)로 맞춘다. 맞출 수 없으면 [UnknownZoneException].
///
/// - `구역/주제`: 구역이 [noteZones]에 있어야 한다. 주제 폴더는 없으면 새로 만든다 (맞는 주제가 없을 때만, 3.3)
/// - `주제`만: 그 이름의 주제가 구역 안에 하나뿐이면 그 주제 (옛 스킬·사람 입력). 아니면 거절
/// - `구역`만, 세 단계 이상: 거절
/// [topicsOf]는 구역 → 그 구역의 기존 주제 이름 (거절 안내와 이름 맞추기에 쓴다).
String resolveTopicPath(String topic, List<String> Function(String zone) topicsOf) {
  if (topic.trim().isEmpty) {
    throw UnknownZoneException(_refusal('구역/주제를 주세요 (--topic "구역/주제").', topicsOf));
  }
  final parts = [for (final part in toNfc(topic.trim()).split('/')) part.trim()];
  if (parts.length == 2 && isZone(parts[0])) {
    final name = topicDirName(parts[1]);
    if (parts[1].isEmpty || name == '미분류' && parts[1] != '미분류') {
      throw UnknownZoneException(_refusal('${parts[0]} 구역의 주제를 고르세요.', topicsOf, zone: parts[0]));
    }
    // 대소문자·띄어쓰기·문장부호만 다른 기존 주제가 있으면 그 이름을 쓴다 (flutter → Flutter, ClaudeCode → Claude Code):
    // 같은 주제가 둘로 갈리지 않게 (11/13 검토)
    final existing = sameTopic(name, topicsOf(parts[0]));
    return '${parts[0]}/${existing ?? name}';
  }
  if (parts.length == 1 && isZone(parts[0])) {
    throw UnknownZoneException(_refusal('${parts[0]} 구역의 주제를 고르세요.', topicsOf, zone: parts[0]));
  }
  if (parts.length == 1 && parts[0].isNotEmpty) {
    final matches = [
      for (final zone in noteZones)
        if (sameTopic(parts[0], topicsOf(zone)) case final t?) '$zone/$t',
    ];
    if (matches.length == 1) return matches.single;
    throw UnknownZoneException(
      _refusal(
        matches.isEmpty
            ? '"${parts[0]}"는 구역/주제가 아닙니다.'
            : '"${parts[0]}" 주제가 여러 구역에 있습니다 (${matches.join(', ')}).',
        topicsOf,
      ),
    );
  }
  if (parts.length >= 2 && !isZone(parts[0])) {
    throw UnknownZoneException(_refusal('"${parts[0]}"는 없는 구역입니다. 구역은 사용자만 만듭니다.', topicsOf));
  }
  throw UnknownZoneException(_refusal('주제 아래에 폴더를 더 만들지 않습니다 ("$topic").', topicsOf));
}

/// 거절 안내: 이유 + 구역 목록(구역마다 주제 최대 12개) 또는 한 구역의 주제 전체 + 다시 저장하는 법.
String _refusal(String reason, List<String> Function(String zone) topicsOf, {String? zone}) {
  final lines = ['저장하지 않았습니다: $reason'];
  if (zone != null) {
    final topics = topicsOf(zone);
    lines.add('$zone 구역의 주제 ${topics.length}개: ${topics.isEmpty ? '(없음)' : topics.join(', ')}');
  } else {
    lines.add('구역(사용자가 정함): ${noteZones.join(', ')}');
    for (final z in noteZones) {
      final topics = topicsOf(z);
      if (topics.isEmpty) continue;
      final shown = topics.take(12).join(', ');
      lines.add('- $z: $shown${topics.length > 12 ? ' 외 ${topics.length - 12}개 (brain topics $z)' : ''}');
    }
  }
  lines
    ..add('--topic "구역/주제"로 다시 저장하세요. 맞는 주제가 있으면 그 주제에, 없을 때만 새 주제를 만듭니다(--new-topic, 주제 전체: brain topics <구역>).')
    ..add(zonePlacementRule);
  return lines.join('\n');
}
