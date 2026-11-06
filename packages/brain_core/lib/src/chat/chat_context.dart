import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../lessons/lesson.dart';
import '../lessons/lesson_store.dart';
import '../note/note.dart';
import '../security/secret_mask.dart';
import '../vault/vault.dart';

/// 경로 B로 보낼 노트 한 개: 제목 + 요약 + 앞부분 500자 (설계서 5.3 보내는 양).
class ChatNote {
  const ChatNote({
    required this.id,
    required this.title,
    required this.summary,
    required this.snippet,
  });

  final String id;
  final String title;
  final String summary;
  final String snippet;

  Map<String, String> toJson() => {
    'id': id,
    'title': title,
    'summary': summary,
    'snippet': snippet,
  };
}

/// 질문 하나에 붙일 근거: 노트 상위 5개 + 맞는 실수 노트 최대 3개.
class ChatContext {
  const ChatContext({required this.notes, required this.lessons});

  final List<ChatNote> notes;
  final List<Lesson> lessons;

  /// 결과가 3개 미만이면 검색어를 다시 만들어 한 번 더 찾는다 (설계서 5.3).
  bool get needsExpansion => notes.length < 3;

  static const maxNotes = 5;
  static const snippetChars = 500;

  static ChatContext build(
    Vault vault,
    SearchIndex index,
    String question, {
    List<String> extraQueries = const [],
  }) {
    final seen = <String>{};
    final docs = <IndexedDoc>[];
    for (final query in [question, ...extraQueries]) {
      for (final doc in index.search(query, limit: maxNotes)) {
        if (doc.isMerged || !seen.add(doc.id)) continue;
        docs.add(doc);
      }
    }
    final notes = [
      for (final doc in docs.take(maxNotes)) ?_read(vault, doc),
    ];
    return ChatContext(
      notes: notes,
      lessons: LessonStore(vault, index).match(question),
    );
  }

  static ChatNote? _read(Vault vault, IndexedDoc doc) {
    final file = File(p.join(vault.root, doc.path));
    if (!file.existsSync()) return null;
    final note = Note.parse(
      file.readAsStringSync(),
      fallbackId: doc.id,
      fallbackTitle: doc.title,
    );
    final body = note.body.trim();
    // 저장할 때 이미 가렸지만, 사용자가 직접 고친 파일일 수 있어 보내기 전에 한 번 더 가린다.
    return ChatNote(
      id: doc.id,
      title: note.title,
      summary: note.summary,
      snippet: maskSecrets(
        body.runes.length <= snippetChars
            ? body
            : String.fromCharCodes(body.runes.take(snippetChars)),
      ),
    );
  }
}

/// 앱 안 AI 질문 기록 `chats/YYYY-MM-DD.md` (설계서 4.1). 서버에는 남기지 않는다.
void appendChatLog(
  Vault vault, {
  required String question,
  required String answer,
  required List<String> usedNoteIds,
  String? correction,
}) {
  final now = DateTime.now();
  final date = formatTime(now).substring(0, 10);
  final file = File(p.join(vault.root, 'chats', '$date.md'));
  file.parent.createSync(recursive: true);
  if (!file.existsSync()) file.writeAsStringSync('# AI 질문 $date\n');
  file.writeAsStringSync(
    [
      '',
      '## ${formatTime(now).substring(11, 16)} ${maskSecrets(question.split('\n').first)}',
      '',
      maskSecrets(question),
      '',
      '**답** (근거: ${usedNoteIds.isEmpty ? '없음' : usedNoteIds.join(', ')})',
      '',
      maskSecrets(answer),
      if (correction != null) ...['', '**교정**: ${maskSecrets(correction)}'],
      '',
    ].join('\n'),
    mode: FileMode.append,
    flush: true,
  );
}

/// 로그 json 편의 (테스트용).
String chatContextJson(ChatContext context) => jsonEncode({
  'notes': [for (final n in context.notes) n.toJson()],
  'lessons': [
    for (final l in context.lessons)
      {'trigger': l.trigger, 'action': l.action, 'reason': l.reason},
  ],
});
