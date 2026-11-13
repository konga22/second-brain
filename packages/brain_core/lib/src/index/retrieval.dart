import 'dart:io';

import 'package:path/path.dart' as p;

import '../lessons/lesson_store.dart';
import '../text/nfc.dart';
import '../vault/vault.dart';
import 'search_index.dart';

/// 찾기 결과를 AI에게 주는 방식 (docs/토큰분석.md 6·7절 비교 실험). `BRAIN_RETRIEVAL` 환경변수로 고른다.
/// - r (기본, 11/07 확정): R1 약한 후보 숨김, R2 질문에 확실한 노트를 훅이 미리 넣음
/// - base: 예전 방식 (find 5줄 제목+요약, 훅은 만들기 요청만) — 비교 실험용
/// - rg: R1·R2 + 깃허브에서 배운 것 (aider 토큰 예산, serena·context7 필요한 줄만, claude-mem 열면 몇 자인지)
enum RetrievalMode {
  base,
  r,
  rg;

  static RetrievalMode get current => switch (Platform.environment['BRAIN_RETRIEVAL']) {
    'base' => RetrievalMode.base,
    'rg' => RetrievalMode.rg,
    _ => RetrievalMode.r,
  };
}

/// 노트 본문 (frontmatter 뺌). 못 읽으면 빈 문자열.
String noteBody(Vault vault, IndexedDoc doc) {
  final file = File(p.join(vault.root, doc.path));
  if (!file.existsSync()) return '';
  final text = file.readAsStringSync();
  if (!text.startsWith('---')) return text;
  final end = text.indexOf('\n---', 3);
  return end < 0 ? text : text.substring(end + 4).trim();
}

/// 질문의 단어 머리가 가장 많이 들어 있는 본문 한 줄 (serena·context7처럼 "필요한 부분만").
/// 맞는 줄이 없으면 null.
String? bestLine(String body, String query, {int max = 120, Set<String> ignore = const {}}) {
  final heads = LessonStore.wordHeads(query).where((h) => !ignore.contains(h)).toList();
  if (heads.isEmpty) return null;
  String? best;
  var bestScore = 0;
  for (final raw in body.split('\n')) {
    final line = raw.trim().replaceFirst(RegExp(r'^[-*#>\d.\s]+'), '');
    if (line.length < 8) continue;
    final lower = toNfc(line).toLowerCase();
    final score = heads.where(lower.contains).length;
    if (score > bestScore) {
      bestScore = score;
      best = line;
    }
  }
  if (best == null) return null;
  return best.length > max ? '${best.substring(0, max)}…' : best;
}
