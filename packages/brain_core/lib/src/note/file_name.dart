import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../text/nfc.dart';

/// 제목을 파일 이름으로 바꾼다 (설계서 4.1 파일 이름 규칙).
/// `/`·`:` 등은 `-`로, 255바이트 안으로, 같은 이름이 있으면 ` (2)`.
String uniqueNotePath(String dir, String title) {
  var base = toNfc(title.trim()).replaceAll(RegExp(r'[/:\\\x00-\x1f]'), '-');
  if (base.isEmpty || base.startsWith('.')) base = '제목 없음$base';
  while (utf8.encode('$base (99).md').length > 255) {
    base = String.fromCharCodes(base.runes.take(base.runes.length - 1));
  }
  var candidate = p.join(dir, '$base.md');
  for (var n = 2; File(candidate).existsSync(); n++) {
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
