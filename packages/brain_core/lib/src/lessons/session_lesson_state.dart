import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../vault/vault.dart';
import 'lesson.dart';

/// 세션 시작 목록에서 **전체 문장으로 보여 준 실수 노트**를 세션별로 적어 둔다 (설계서_프롬프트이후 6.4).
///
/// 요청 훅은 요청에 맞는 실수 노트를 요청마다 다시 넣는다. 이 세션이 세션 시작 목록에서 같은 문장을 이미 봤으면
/// 번호만 넣어도 된다 — 그런데 "봤다"를 추측하면 틀린다: 세션 시작 뒤 고친 규칙, 목록에서 잘린 규칙(행동 120자 넘음),
/// 30개 밖 규칙, 세션 시작 훅이 돌지 않은 세션은 AI가 그 문장을 본 적이 없다. 그래서 세션 시작 훅이 실제로 보여 준 것을
/// 적어 두고, 요청 훅은 지금 규칙과 견줘 **같을 때만** 번호로 줄인다. 파일이 없거나 못 읽으면 "본 것 없음"이다(전체 문장으로 넣는다).
///
/// 자리는 색인 캐시 폴더(`~/Library/Caches/<번들 ID>/<폴더 해시>/session-lessons/`)다. 지식 폴더 밖이고 번호와 해시만 있다.
class SessionLessonState {
  SessionLessonState(this.vault);

  final Vault vault;

  /// 이보다 오래된 세션 파일은 [record] 때 지운다.
  static const keepFor = Duration(days: 14);

  String get _dir => p.join(p.dirname(vault.indexPath), 'session-lessons');

  /// 세션 id는 Claude Code가 주는 값이지만 파일 이름으로 쓰므로 글자를 좁힌다 (경로 조작 방지).
  static final _safeId = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  File? _file(Object? sessionId) =>
      sessionId is String && _safeId.hasMatch(sessionId) ? File(p.join(_dir, sessionId)) : null;

  /// 규칙 문장의 지문. 상황·행동 가운데 한 글자라도 바뀌면 달라진다.
  static String digest(Lesson lesson) =>
      sha1.convert(utf8.encode('${lesson.trigger}\n${lesson.action}')).toString().substring(0, 16);

  /// 세션 시작 목록에 [fullyShown](자르지 않고 보여 준 규칙)을 적는다. 세션 시작 훅이 돌 때마다(시작·다시 열기·압축 뒤) 새로 쓴다.
  /// 실패해도 던지지 않는다 — 못 적으면 요청 훅이 전체 문장으로 넣을 뿐이다.
  void record(Object? sessionId, Iterable<Lesson> fullyShown) {
    final file = _file(sessionId);
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      _prune(file.parent);
      // 요청 훅이 쓰는 도중의 파일을 읽지 않게 임시 파일 → 이름 바꾸기로 쓴다
      writeFileAtomic(file.path, [for (final l in fullyShown) '${l.id} ${digest(l)}'].join('\n'));
    } on FileSystemException {
      // 캐시를 못 쓰는 환경: 줄이지 않고 전체 문장으로 넣게 된다
    }
  }

  /// 이 세션이 세션 시작 목록에서 전체 문장으로 본 규칙: 번호 → 지문. 기록이 없으면 빈 맵.
  Map<String, String> shown(Object? sessionId) {
    final file = _file(sessionId);
    if (file == null) return const {};
    try {
      if (!file.existsSync()) return const {};
      return {
        for (final line in file.readAsLinesSync())
          if (line.split(' ') case [final id, final hash]) id: hash,
      };
    } on FileSystemException {
      return const {};
    }
  }

  /// [lesson]을 이 세션이 지금 문장 그대로 봤는가.
  static bool isShown(Map<String, String> shown, Lesson lesson) => shown[lesson.id] == digest(lesson);

  void _prune(Directory dir) {
    final cutoff = DateTime.now().subtract(keepFor);
    for (final entry in dir.listSync(followLinks: false)) {
      if (entry is File && entry.statSync().modified.isBefore(cutoff)) {
        try {
          entry.deleteSync();
        } on FileSystemException {
          // 다른 프로세스가 먼저 지웠다
        }
      }
    }
  }
}

/// 요청 훅이 세션 시작 목록에서 이미 본 실수 노트를 다시 알리는 방식 (설계서_프롬프트이후 6.4). `BRAIN_LESSON_REMIND`로 고른다.
/// - full: 늘 전체 문장 (11/14까지의 방식)
/// - ids: 이미 본 규칙은 번호만 한 줄로
/// - none: 이미 본 규칙은 넣지 않는다 — 대조군(실측용)
enum LessonRemind {
  full,
  ids,
  none;

  /// 기본값. 규칙 지킴을 잰 뒤에 정한다 (재기 전에는 지금과 같은 [full]).
  static const fallback = LessonRemind.full;

  static LessonRemind get current => switch (Platform.environment['BRAIN_LESSON_REMIND']) {
    'full' => LessonRemind.full,
    'ids' => LessonRemind.ids,
    'none' => LessonRemind.none,
    _ => fallback,
  };
}
