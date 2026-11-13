import 'dart:io';

import 'package:path/path.dart' as p;

import '../note/note.dart';
import '../vault/vault.dart';
import 'claude_sessions.dart';

/// 세션 축약본을 `raw/sessions/<날짜>-<id>.md`에 남긴다 (설계서 5.6 원본 보관).
/// 같은 세션이 그 뒤 더 이어졌으면(대화 수가 늘면) 다시 쓴다. 예전에는 첫 저장 때 한 번만 남겨 그 뒤 대화에서
/// 나온 노트의 근거가 축약본에 없었다 (11/11 K-35).
///
/// 노트의 근거가 될 때, 또는 화면 없는 실행이 실패했을 때 나중에 정리하려고 남긴다.
/// 반환: 지식 폴더 기준 상대 경로.
String archiveSession(Vault vault, ClaudeSessions sessions, ClaudeSession session) {
  final date = (session.start ?? DateTime.now()).toLocal().toIso8601String().substring(0, 10);
  final path = p.join(vault.rawSessionsDir, '$date-${session.shortId}.md');
  final file = File(path);
  final summary = '${session.project} 대화 ${session.dialogueCount}개';
  final clipped = String.fromCharCodes(summary.runes.take(60));
  final existing = file.existsSync() ? Note.parse(file.readAsStringSync(), fallbackId: '', fallbackTitle: '') : null;
  if (existing == null || existing.summary != clipped) {
    final note = Note(
      id: 'r_${session.shortId}',
      title: '세션 ${session.shortId} ${session.title}',
      summary: clipped,
      source: 'session',
      sources: [session.path],
      created: existing?.created ?? DateTime.now(),
      updated: existing == null ? null : DateTime.now(),
      body: sessions.condense(session),
    );
    writeFileAtomic(path, note.toMarkdown());
  }
  return p.relative(path, from: vault.root);
}
