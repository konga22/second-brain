import 'dart:io';

import 'package:path/path.dart' as p;

import '../note/note.dart';
import '../vault/vault.dart';
import 'claude_sessions.dart';

/// 세션 축약본을 `raw/sessions/<날짜>-<id>.md`에 한 번만 남긴다 (설계서 5.6 원본 보관).
///
/// 노트의 근거가 될 때, 또는 화면 없는 실행이 실패했을 때 나중에 정리하려고 남긴다.
/// 반환: 지식 폴더 기준 상대 경로.
String archiveSession(Vault vault, ClaudeSessions sessions, ClaudeSession session) {
  final date = (session.start ?? DateTime.now()).toLocal().toIso8601String().substring(0, 10);
  final path = p.join(vault.rawSessionsDir, '$date-${session.shortId}.md');
  final file = File(path);
  if (!file.existsSync()) {
    final summary = '${session.project} 대화 ${session.dialogueCount}개';
    final note = Note(
      id: 'r_${session.shortId}',
      title: '세션 ${session.shortId} ${session.title}',
      summary: String.fromCharCodes(summary.runes.take(60)),
      source: 'session',
      sources: [session.path],
      created: DateTime.now(),
      body: sessions.condense(session),
    );
    writeFileAtomic(path, note.toMarkdown());
  }
  return p.relative(path, from: vault.root);
}
