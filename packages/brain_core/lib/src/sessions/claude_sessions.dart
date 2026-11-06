import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../security/secret_mask.dart';
import '../vault/vault.dart';

/// 축약본의 한 줄: 사용자 문장, AI 문장, 또는 "도구 N개 실행".
class DialogueLine {
  const DialogueLine(this.role, this.text);

  /// `user` | `ai` | `tools`
  final String role;
  final String text;
}

/// Claude Code 세션 한 개의 요약 (설계서 5.6).
class ClaudeSession {
  const ClaudeSession({
    required this.sessionId,
    required this.path,
    required this.cwd,
    required this.gitBranch,
    required this.start,
    required this.end,
    required this.title,
    required this.userCount,
    required this.aiCount,
    required this.toolCount,
  });

  final String sessionId;
  final String path;
  final String cwd;
  final String gitBranch;
  final DateTime? start;
  final DateTime? end;
  final String title;
  final int userCount;
  final int aiCount;
  final int toolCount;

  String get shortId =>
      sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;

  /// 작업 폴더 이름 (프로젝트).
  String get project => cwd.isEmpty ? '(알 수 없음)' : p.basename(cwd);

  int get dialogueCount => userCount + aiCount;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'path': path,
    'cwd': cwd,
    'gitBranch': gitBranch,
    'start': start?.toIso8601String(),
    'end': end?.toIso8601String(),
    'title': title,
    'userCount': userCount,
    'aiCount': aiCount,
    'toolCount': toolCount,
  };

  static ClaudeSession fromJson(Map<String, dynamic> json) => ClaudeSession(
    sessionId: json['sessionId'] as String,
    path: json['path'] as String,
    cwd: json['cwd'] as String,
    gitBranch: json['gitBranch'] as String,
    start: DateTime.tryParse('${json['start']}'),
    end: DateTime.tryParse('${json['end']}'),
    title: json['title'] as String,
    userCount: json['userCount'] as int,
    aiCount: json['aiCount'] as int,
    toolCount: json['toolCount'] as int,
  );
}

/// `~/.claude/projects/<폴더>/<세션>.jsonl`을 읽는다. 원본은 복사하지 않는다.
class ClaudeSessions {
  ClaudeSessions({String? projectsDir, this.cacheDb})
    : projectsDir =
          projectsDir ??
          p.join(Platform.environment['HOME'] ?? '.', '.claude', 'projects');

  final String projectsDir;

  /// `SearchIndex.db`의 `session_cache` 표. 없으면 매번 다시 읽는다.
  final Database? cacheDb;

  /// 세션 목록. 자동 제외: 지식 폴더 안 세션, 사용자 문장 2개 미만 (설계서 5.6).
  List<ClaudeSession> list({required Vault vault, Duration? since}) {
    final dir = Directory(projectsDir);
    if (!dir.existsSync()) return const [];
    final cutoff = since == null ? null : DateTime.now().subtract(since);
    final sessions = <ClaudeSession>[];
    for (final project in dir.listSync().whereType<Directory>()) {
      for (final file in project.listSync().whereType<File>()) {
        if (!file.path.endsWith('.jsonl')) continue;
        final stat = file.statSync();
        if (cutoff != null && stat.modified.isBefore(cutoff)) continue;
        final session = _summary(file, stat);
        if (session == null || session.userCount < 2) continue;
        if (session.cwd.isNotEmpty && vault.contains(session.cwd)) continue;
        sessions.add(session);
      }
    }
    sessions.sort(
      (a, b) => (b.end ?? DateTime(0)).compareTo(a.end ?? DateTime(0)),
    );
    return sessions;
  }

  /// 앞 6자 이상으로 세션을 찾는다.
  ///
  /// 세션 파일 이름이 세션 id라서 이름으로 바로 찾는다. 목록(list)의 걸러 내기
  /// (사용자 대화 2개 미만, 지식 폴더 안 세션)는 적용하지 않는다: 대화 중 자동 저장은
  /// 첫 메시지에서도 그 세션을 근거로 남겨야 하기 때문이다 (사용기 #17).
  ClaudeSession? find(String idPrefix, {required Vault vault}) {
    if (idPrefix.length < 6) return null;
    final dir = Directory(projectsDir);
    if (!dir.existsSync()) return null;
    for (final project in dir.listSync().whereType<Directory>()) {
      for (final file in project.listSync().whereType<File>()) {
        final name = file.uri.pathSegments.last;
        if (!name.endsWith('.jsonl') || !name.startsWith(idPrefix)) continue;
        final session = _summary(file, file.statSync());
        if (session != null) return session;
      }
    }
    return null;
  }

  ClaudeSession? _summary(File file, FileStat stat) {
    final cache = cacheDb;
    final mtime = stat.modified.millisecondsSinceEpoch;
    if (cache != null) {
      final rows = cache.select(
        'select summary from session_cache where path = ? and mtime = ? and size = ?',
        [file.path, mtime, stat.size],
      );
      if (rows.isNotEmpty) {
        return ClaudeSession.fromJson(
          jsonDecode(rows.first['summary'] as String) as Map<String, dynamic>,
        );
      }
    }
    final (session, _) = _parse(file);
    if (session != null && cache != null) {
      cache.execute(
        'insert or replace into session_cache(path, mtime, size, summary) values (?, ?, ?, ?)',
        [file.path, mtime, stat.size, jsonEncode(session.toJson())],
      );
    }
    return session;
  }

  /// 세션 축약본: 대화 문장만, 도구는 한 줄 요약, 비밀값 가림.
  String condense(ClaudeSession session) {
    final (_, lines) = _parse(File(session.path));
    final date = session.start == null ? '' : _date(session.start!);
    final header =
        '${session.shortId} · $date · Claude Code · ${session.cwd}'
        '${session.gitBranch.isEmpty ? '' : ' · ${session.gitBranch}'} · 대화 ${session.dialogueCount}개';
    final body = lines.map(
      (line) => switch (line.role) {
        'user' => '[사용자] ${line.text}',
        'ai' => '[AI] ${line.text}',
        _ => '(${line.text})',
      },
    );
    return maskSecrets([header, ...body].join('\n\n'));
  }

  static String _date(DateTime time) {
    final t = time.toLocal();
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  static final _reminder = RegExp(
    r'<system-reminder>[\s\S]*?</system-reminder>',
  );

  /// 한 번 읽으면서 요약과 대화 줄을 함께 만든다.
  (ClaudeSession?, List<DialogueLine>) _parse(File file) {
    final lines = <DialogueLine>[];
    var sessionId = p.basenameWithoutExtension(file.path);
    var cwd = '';
    var branch = '';
    DateTime? start;
    DateTime? end;
    String? customTitle;
    var users = 0;
    var ais = 0;
    var tools = 0;
    var pendingTools = 0;

    void add(String role, String text) {
      if (pendingTools > 0) {
        lines.add(DialogueLine('tools', '도구 $pendingTools개 실행'));
        pendingTools = 0;
      }
      if (lines.isNotEmpty && lines.last.role == role && role == 'ai') {
        lines[lines.length - 1] = DialogueLine(
          role,
          '${lines.last.text}\n${text.trim()}',
        );
      } else {
        lines.add(DialogueLine(role, text.trim()));
      }
    }

    for (final raw in file.readAsLinesSync()) {
      if (!raw.contains('"type":"user"') &&
          !raw.contains('"type":"assistant"') &&
          !raw.contains('"type":"custom-title"')) {
        continue;
      }
      Map<String, dynamic> record;
      try {
        record = jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        continue;
      }
      final type = record['type'];
      if (type == 'custom-title') {
        customTitle = '${record['customTitle'] ?? ''}'.trim();
        continue;
      }
      if (type != 'user' && type != 'assistant') continue;
      if (record['isSidechain'] == true ||
          record['isMeta'] == true ||
          record['isCompactSummary'] == true) {
        continue;
      }
      sessionId = '${record['sessionId'] ?? sessionId}';
      if (cwd.isEmpty) cwd = '${record['cwd'] ?? ''}';
      if (branch.isEmpty) branch = '${record['gitBranch'] ?? ''}';
      final time = DateTime.tryParse('${record['timestamp'] ?? ''}');
      if (time != null) {
        start ??= time;
        end = time;
      }
      final content = (record['message'] as Map<String, dynamic>?)?['content'];
      if (type == 'user') {
        final text = _userText(content);
        if (text == null) continue;
        users++;
        add('user', text);
      } else if (content is List) {
        for (final block in content.whereType<Map<String, dynamic>>()) {
          if (block['type'] == 'tool_use') {
            tools++;
            pendingTools++;
          } else if (block['type'] == 'text') {
            final text = '${block['text'] ?? ''}'.trim();
            if (text.isEmpty) continue;
            ais++;
            add('ai', text);
          }
        }
      }
    }
    if (users == 0 && ais == 0) return (null, lines);
    final firstUser = lines
        .firstWhere(
          (l) => l.role == 'user',
          orElse: () => const DialogueLine('user', ''),
        )
        .text;
    final title = (customTitle != null && customTitle.isNotEmpty)
        ? customTitle
        : String.fromCharCodes(
            firstUser.replaceAll(RegExp(r'\s+'), ' ').runes.take(50),
          );
    return (
      ClaudeSession(
        sessionId: sessionId,
        path: file.path,
        cwd: cwd,
        gitBranch: branch,
        start: start,
        end: end,
        title: title,
        userCount: users,
        aiCount: ais,
        toolCount: tools,
      ),
      lines,
    );
  }

  /// 사람이 쓴 문장만 남긴다. 명령 출력·도구 결과·시스템 알림은 뺀다.
  String? _userText(Object? content) {
    String text;
    if (content is String) {
      text = content;
    } else if (content is List) {
      final parts = <String>[];
      for (final block in content.whereType<Map<String, dynamic>>()) {
        if (block['type'] == 'text') parts.add('${block['text'] ?? ''}');
        if (block['type'] == 'image') parts.add('(이미지)');
      }
      if (parts.isEmpty) return null;
      text = parts.join('\n');
    } else {
      return null;
    }
    text = text.replaceAll(_reminder, '').trim();
    if (text.isEmpty) return null;
    if (text.startsWith('<command-') ||
        text.startsWith('<local-command') ||
        text.startsWith('<bash-')) {
      return null;
    }
    if (text.startsWith('[Request interrupted')) return null;
    return text;
  }
}
