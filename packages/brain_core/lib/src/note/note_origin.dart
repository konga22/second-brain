import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../vault/vault.dart';
import 'note.dart';

/// 노트 출처의 종류.
enum NoteOriginKind {
  /// AI 대화 세션에서 뽑은 지식 (`raw/sessions/<날짜>-<세션>.md`).
  session,

  /// 가져온 파일 (`raw/imports/...`).
  importFile,

  /// 세션 축약본이 가리키는 대화 기록 파일 (`*.jsonl`).
  sessionLog,

  /// 그 밖의 경로.
  other,
}

/// 노트가 어디서 왔는지 (설계서 3.0 출처 표시, v1.3.26).
///
/// 노트의 `sources`에는 경로만 있다. 그 경로를 "어느 도구·프로젝트·세션"으로 풀어 화면에 보인다.
class NoteOrigin {
  const NoteOrigin({
    required this.kind,
    required this.path,
    this.tool,
    this.project,
    this.sessionId,
    this.title,
    this.date,
    this.dialogueCount,
    this.rawId,
  });

  final NoteOriginKind kind;

  /// `sources`에 적힌 그대로의 경로.
  final String path;

  /// `Claude Code`·`Codex`. 알 수 없으면 null.
  final String? tool;

  /// 세션을 연 작업 폴더 이름.
  final String? project;

  /// 세션 id 앞 8자.
  final String? sessionId;

  /// 세션 제목 또는 가져온 파일 이름.
  final String? title;

  /// `2026-11-09` — 세션을 시작한 날 또는 가져온 날.
  final String? date;

  /// 세션의 대화 문장 수.
  final int? dialogueCount;

  /// 원본 노트가 지식 폴더에 있으면 그 id (`r_<세션>`). 화면에서 눌러 열 때 쓴다.
  final String? rawId;

  /// 한 줄 표시: `Claude Code · second-brain 세션`.
  String get shortLabel {
    switch (kind) {
      case NoteOriginKind.session:
        final who = tool ?? 'AI 대화';
        return project == null ? '$who 세션 ${sessionId ?? ''}'.trim() : '$who · $project 세션';
      case NoteOriginKind.importFile:
        return '가져온 파일 · ${title ?? p.basename(path)}';
      case NoteOriginKind.sessionLog:
        final who = tool ?? 'AI 대화';
        return project == null ? '$who 대화 기록' : '$who · $project 대화 기록';
      case NoteOriginKind.other:
        return p.basename(path);
    }
  }

  /// 둘째 줄 표시: `2026-11-09 시작 · 세션 e080b491 · 대화 241개`. 없는 값은 뺀다.
  String get detail => [
    if (date != null) kind == NoteOriginKind.importFile ? '$date 가져옴' : '$date 시작',
    if (sessionId != null) '세션 $sessionId',
    if (dialogueCount != null) '대화 $dialogueCount개',
  ].join(' · ');
}

final _sessionPath = RegExp(r'raw/sessions/(\d{4}-\d{2}-\d{2})-([0-9A-Za-z]+)\.md$');
final _importPath = RegExp(r'raw/imports/(?:(\d{4}-\d{2}-\d{2})-)?([^/]+)$');
final _projectCount = RegExp(r'^(.+) 대화 (\d+)개$');
final _titlePrefix = RegExp(r'^세션 \S+ ?');

String? _toolOf(String logPath) {
  if (logPath.contains('/.claude/')) return 'Claude Code';
  if (logPath.contains('/.codex/')) return 'Codex';
  return null;
}

/// 파일 앞부분만 읽는다. 세션 축약본은 10만 자를 넘기도 해서 머리말만 필요할 때 쓴다.
String _head(String path, [int bytes = 4096]) {
  final file = File(path);
  if (!file.existsSync()) return '';
  final handle = file.openSync();
  try {
    return utf8.decode(handle.readSync(bytes), allowMalformed: true);
  } on FileSystemException {
    return '';
  } finally {
    handle.closeSync();
  }
}

/// [note]의 `sources`를 출처로 푼다. 원본 파일이 없어도 경로에서 알 수 있는 것(날짜·세션 id)은 채운다.
List<NoteOrigin> resolveOrigins(Vault vault, Note note) => [
  for (final source in note.sources) _resolve(vault, note, source),
];

NoteOrigin _resolve(Vault vault, Note note, String source) {
  final path = source.replaceAll(r'\', '/');
  final session = _sessionPath.firstMatch(path);
  if (session != null) {
    final head = _head(p.isAbsolute(source) ? source : p.join(vault.root, source));
    if (head.isEmpty) {
      return NoteOrigin(
        kind: NoteOriginKind.session,
        path: source,
        date: session.group(1),
        sessionId: session.group(2),
      );
    }
    final raw = Note.parse(head, fallbackId: 'r_${session.group(2)}', fallbackTitle: '');
    final count = _projectCount.firstMatch(raw.summary);
    final title = raw.title.replaceFirst(_titlePrefix, '').trim();
    return NoteOrigin(
      kind: NoteOriginKind.session,
      path: source,
      tool: raw.sources.isEmpty ? null : _toolOf(raw.sources.first),
      project: count?.group(1),
      sessionId: session.group(2),
      title: title.isEmpty ? null : title,
      date: session.group(1),
      dialogueCount: count == null ? null : int.tryParse(count.group(2)!),
      rawId: raw.id,
    );
  }
  final imported = _importPath.firstMatch(path);
  if (imported != null) {
    return NoteOrigin(
      kind: NoteOriginKind.importFile,
      path: source,
      title: imported.group(2),
      date: imported.group(1),
    );
  }
  if (path.endsWith('.jsonl')) {
    final count = _projectCount.firstMatch(note.summary);
    return NoteOrigin(
      kind: NoteOriginKind.sessionLog,
      path: source,
      tool: _toolOf(path),
      project: count?.group(1),
      dialogueCount: count == null ? null : int.tryParse(count.group(2)!),
    );
  }
  return NoteOrigin(kind: NoteOriginKind.other, path: source);
}
