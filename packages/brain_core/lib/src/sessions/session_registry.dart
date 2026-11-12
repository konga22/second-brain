import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../note/note.dart';
import '../vault/vault.dart';

/// 세션 처리 상태. `_meta/sessions.jsonl`에 추가만 하고, 마지막 줄이 이긴다.
enum SessionStatus {
  unsaved('unsaved', '저장 안 함'),
  saved('saved', '저장함'),
  skipped('skipped', '저장할 것 없음'),

  /// 다 읽지 않고 저장함: 처리가 안 끝나 자동 정리·지난 대화 목록에 다시 나온다 (11/12 K-40, 설계서 5.6 v1.3.37).
  partial('partial', '일부 저장');

  const SessionStatus(this.value, this.label);

  final String value;
  final String label;

  bool get isDone => this == saved || this == skipped;

  static SessionStatus parse(Object? value) =>
      values.firstWhere((s) => s.value == value, orElse: () => unsaved);
}

class SessionRegistry {
  SessionRegistry(this.vault);

  final Vault vault;

  File get _file => File(p.join(vault.metaDir, 'sessions.jsonl'));

  Map<String, SessionStatus> load() {
    final result = <String, SessionStatus>{};
    if (!_file.existsSync()) return result;
    for (final line in _file.readAsLinesSync()) {
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        result[json['id'] as String] = SessionStatus.parse(json['status']);
      } on FormatException {
        continue;
      }
    }
    return result;
  }

  /// 세션에서 저장한 노트 id (모든 줄의 `notes`를 모은다).
  List<String> notesOf(String sessionId) {
    if (!_file.existsSync()) return const [];
    final result = <String>[];
    for (final line in _file.readAsLinesSync()) {
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        if (json['id'] != sessionId) continue;
        for (final note in json['notes'] as List<dynamic>? ?? const []) {
          if (!result.contains(note)) result.add(note as String);
        }
      } on FormatException {
        continue;
      }
    }
    return result;
  }

  /// SessionEnd 훅에서 부른다. 빨라야 해서 파일 끝에 한 줄만 붙인다.
  void mark(
    String sessionId,
    SessionStatus status, {
    String? transcriptPath,
    List<String> notes = const [],
  }) {
    _file.parent.createSync(recursive: true);
    final line = jsonEncode({
      'id': sessionId,
      'status': status.value,
      'at': formatTime(DateTime.now()),
      'path': ?transcriptPath,
      if (notes.isNotEmpty) 'notes': notes,
    });
    _file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }
}
