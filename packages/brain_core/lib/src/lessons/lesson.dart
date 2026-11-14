import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../note/note.dart';
import '../text/nfc.dart';

/// 실수 노트 상태 (설계서 5.4).
enum LessonStatus {
  pending('pending', '승인 대기'),
  active('active', '적용'),
  archived('archived', '보관');

  const LessonStatus(this.value, this.label);

  final String value;
  final String label;

  static LessonStatus parse(Object? value) => values.firstWhere(
    (s) => s.value == value,
    orElse: () => LessonStatus.pending,
  );
}

/// 실수 노트 `lessons/L-0007.md`: 언제(trigger) → 무엇을(action) → 왜(reason).
class Lesson {
  const Lesson({
    required this.id,
    required this.trigger,
    required this.action,
    required this.reason,
    this.status = LessonStatus.pending,
    this.source = 'explicit',
    this.diff = '',
    this.tests = const [],
    this.kept = 0,
    this.recorrected = 0,
    this.lastSeen,
    this.created,
    this.recorrectedAt,
    this.body = '',
  });

  final String id;
  final String trigger;
  final String action;
  final String reason;
  final LessonStatus status;

  /// explicit(직접 교정) | observed(자동 감지)
  final String source;

  /// AI가 쓴 것 → 사용자가 고친 것 (`- 전`, `+ 후` 줄).
  final String diff;
  final List<String> tests;

  /// 지켜서 문제없던 횟수, 다시 교정된 횟수 (검증 에이전트 판단 근거).
  final int kept;
  final int recorrected;
  final DateTime? lastSeen;

  /// 만든 날과 마지막으로 다시 교정된 날 (설계서_프롬프트이후 4.5: 세션 시작 목록을 최근순으로 고른다).
  /// 이 필드가 생기기 전에 만든 규칙은 null이다.
  final DateTime? created;
  final DateTime? recorrectedAt;

  /// 만들었거나 다시 교정된 가장 늦은 날. 둘 다 없으면 null (가장 오래된 쪽으로 친다).
  DateTime? get touched => switch ((created, recorrectedAt)) {
    (final c?, final r?) => r.isAfter(c) ? r : c,
    (final c, final r) => c ?? r,
  };

  /// 최근에 만들었거나 다시 교정된 것부터 (설계서_프롬프트이후 4.5). 날이 같거나 없으면 번호가 큰(나중에 만든) 것부터.
  /// 파일에 적힌 값만 써서 규칙이 안 바뀌면 순서도 안 바뀐다 (세션 시작 안내는 프롬프트 캐시).
  static int recentFirst(Lesson a, Lesson b) {
    final ta = a.touched, tb = b.touched;
    if (ta == null && tb != null) return 1;
    if (tb == null && ta != null) return -1;
    // `!=`는 UTC 여부까지 비교해 같은 시각이 0을 돌려 번호 순 비교를 건너뛸 수 있었다 → compareTo로 (11/13 검토)
    final byTime = ta == null || tb == null ? 0 : tb.compareTo(ta);
    return byTime != 0 ? byTime : b.id.compareTo(a.id);
  }

  /// 교정 원문과 검증 에이전트 판단 기록.
  final String body;

  /// 훅·검색 결과 한 줄: `결제 코드 수정 시 → 테스트 키로 먼저 확인`.
  String get line => '$trigger → $action';

  static Lesson parse(String text, {required String fallbackId}) {
    final (meta, body) = _frontmatter(text);
    final evidence = meta['evidence'] is Map ? meta['evidence'] as Map : const {};
    return Lesson(
      id: '${meta['id'] ?? fallbackId}',
      trigger: toNfc('${meta['trigger'] ?? ''}'),
      action: toNfc('${meta['action'] ?? ''}'),
      reason: toNfc('${meta['reason'] ?? ''}'),
      status: LessonStatus.parse(meta['status']),
      source: '${meta['source'] ?? 'explicit'}',
      diff: '${meta['diff'] ?? ''}'.trimRight(),
      tests: meta['tests'] is List
          ? [for (final t in meta['tests'] as List) '$t']
          : const [],
      kept: int.tryParse('${evidence['kept'] ?? 0}') ?? 0,
      recorrected: int.tryParse('${evidence['recorrected'] ?? 0}') ?? 0,
      lastSeen: DateTime.tryParse('${evidence['lastSeen'] ?? ''}'),
      created: DateTime.tryParse('${meta['created'] ?? ''}'),
      recorrectedAt: DateTime.tryParse('${evidence['recorrectedAt'] ?? ''}'),
      body: body,
    );
  }

  String toMarkdown() {
    String q(String s) => jsonEncode(s);
    final diffLines = diff.trim().isEmpty
        ? ['diff: ""']
        : ['diff: |', for (final l in diff.trimRight().split('\n')) '  $l'];
    String day(DateTime t) => formatTime(t).substring(0, 10);
    final seen = [
      if (lastSeen != null) ', lastSeen: ${day(lastSeen!)}',
      if (recorrectedAt != null) ', recorrectedAt: ${day(recorrectedAt!)}',
    ].join();
    return [
      '---',
      'id: $id',
      'status: ${status.value}',
      'trigger: ${q(trigger)}',
      'action: ${q(action)}',
      'reason: ${q(reason)}',
      'source: $source',
      ...diffLines,
      'tests: [${tests.join(', ')}]',
      if (created != null) 'created: ${day(created!)}',
      'evidence: { kept: $kept, recorrected: $recorrected$seen }',
      '---',
      body.trim(),
      '',
    ].join('\n');
  }

  Lesson copyWith({
    LessonStatus? status,
    List<String>? tests,
    int? kept,
    int? recorrected,
    DateTime? lastSeen,
    DateTime? recorrectedAt,
    String? trigger,
    String? action,
    String? reason,
    String? diff,
    String? body,
  }) => Lesson(
    id: id,
    trigger: trigger ?? this.trigger,
    action: action ?? this.action,
    reason: reason ?? this.reason,
    status: status ?? this.status,
    source: source,
    diff: diff ?? this.diff,
    tests: tests ?? this.tests,
    kept: kept ?? this.kept,
    recorrected: recorrected ?? this.recorrected,
    lastSeen: lastSeen ?? this.lastSeen,
    created: created,
    recorrectedAt: recorrectedAt ?? this.recorrectedAt,
    body: body ?? this.body,
  );
}

/// 회귀 시험 사례 `lessons/tests/T-0003.md` (설계서 4.1).
class LessonTest {
  const LessonTest({
    required this.id,
    required this.lesson,
    required this.question,
    required this.bad,
    required this.expect,
  });

  final String id;
  final String lesson;
  final String question;

  /// 교정 전 답의 요지.
  final String bad;

  /// 통과 조건.
  final String expect;

  static LessonTest parse(String text, {required String fallbackId}) {
    final (meta, _) = _frontmatter(text);
    return LessonTest(
      id: '${meta['id'] ?? fallbackId}',
      lesson: '${meta['lesson'] ?? ''}',
      question: toNfc('${meta['question'] ?? ''}'),
      bad: toNfc('${meta['bad'] ?? ''}'),
      expect: toNfc('${meta['expect'] ?? ''}'),
    );
  }

  String toMarkdown() {
    String q(String s) => jsonEncode(s);
    return [
      '---',
      'id: $id',
      'lesson: $lesson',
      'question: ${q(question)}',
      'bad: ${q(bad)}',
      'expect: ${q(expect)}',
      '---',
      '',
    ].join('\n');
  }
}

(Map<String, Object?>, String) _frontmatter(String text) {
  final match = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---\r?\n?').firstMatch(text);
  if (match == null) return (const {}, text);
  try {
    final yaml = loadYaml(match.group(1)!);
    if (yaml is YamlMap) {
      return (
        {for (final e in yaml.entries) '${e.key}': _plain(e.value)},
        text.substring(match.end),
      );
    }
  } on YamlException {
    // 형식이 깨졌으면 빈 값으로 읽는다. brain lint가 잡는다.
  }
  return (const {}, text.substring(match.end));
}

Object? _plain(Object? value) => switch (value) {
  YamlList() => [for (final v in value) _plain(v)],
  YamlMap() => {for (final e in value.entries) '${e.key}': _plain(e.value)},
  _ => value,
};
