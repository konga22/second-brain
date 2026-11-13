import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../text/nfc.dart';

/// 제목을 파일 이름으로 바꾼다 (설계서 4.1 파일 이름 규칙).
/// `/`·`:` 등은 `-`로, 255바이트 안으로, 같은 이름이 있으면 ` (2)`.
///
/// [self]: 지금 이 노트의 파일 경로. 새 이름이 그 파일과 같으면 ` (2)`를 붙이지 않고 그대로 돌려준다
/// (짧은 이름은 제목을 고쳐도 같을 때가 많다, 설계서_프롬프트이후 5.1).
String uniqueNotePath(String dir, String title, {String? self}) {
  var base = toNfc(title.trim()).replaceAll(RegExp(r'[/:\\\x00-\x1f]'), '-');
  if (base.isEmpty || base.startsWith('.')) base = '제목 없음$base';
  // 색인은 `_`로 시작하는 파일과 `index.md`(자동 목차)를 노트로 보지 않는다. 그런 이름으로 저장하면
  // "저장함"이 나와도 찾을 수 없고 다음 노트가 같은 id를 받았다 (11/11 K-26). 파일 이름만 바꾸고 제목은 그대로 둔다.
  if (base.startsWith('_')) base = '＿${base.substring(1)}';
  if (base.toLowerCase() == 'index') base = '$base (노트)';
  // 원자적 쓰기의 임시 파일 접미사(`.tmp-` + 마이크로초 16자리)까지 255바이트 안에 들어가야 한다.
  while (utf8.encode('$base (99).md.tmp-0000000000000000').length > 255) {
    base = String.fromCharCodes(base.runes.take(base.runes.length - 1));
  }
  var candidate = p.join(dir, '$base.md');
  for (var n = 2; candidate != self && File(candidate).existsSync(); n++) {
    candidate = p.join(dir, '$base ($n).md');
  }
  return candidate;
}

/// 주제 폴더 이름. 비면 "미분류".
String topicDirName(String? topic) {
  final cleaned = toNfc((topic ?? '').trim()).replaceAll(
    RegExp(r'[/:\\\x00-\x1f]'),
    '-',
  );
  return cleaned.isEmpty || cleaned.startsWith('.') ? '미분류' : cleaned;
}
