import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../text/nfc.dart';

/// 노트 상태 (설계서 4.1).
enum NoteStatus {
  draft('draft', '정리 대기'),
  active('active', '정리됨'),
  merged('merged', '합쳐짐');

  const NoteStatus(this.value, this.label);

  final String value;
  final String label;

  static NoteStatus parse(Object? value) => values.firstWhere(
    (status) => status.value == value,
    orElse: () => NoteStatus.active,
  );
}

/// md 노트 한 개. frontmatter + 본문.
class Note {
  const Note({
    required this.id,
    required this.title,
    required this.body,
    this.summary = '',
    this.tags = const [],
    this.aliases = const [],
    this.source = 'manual',
    this.sources = const [],
    this.created,
    this.updated,
    this.status = NoteStatus.active,
    this.extra = const {},
    this.isFrontmatterBroken = false,
  });

  final String id;
  final String title;
  final String summary;
  final List<String> tags;
  final List<String> aliases;
  final String source;
  final List<String> sources;
  final DateTime? created;
  final DateTime? updated;
  final NoteStatus status;
  final String body;

  /// 우리가 모르는 frontmatter 키. 다시 쓸 때 그대로 남긴다.
  final Map<String, Object?> extra;

  /// frontmatter 블록은 있는데 YAML로 읽지 못했다 (예: `title: 결제: 재시도`, 중복 키).
  /// 이런 노트를 다시 쓰면 제목·요약·태그·출처가 기본값으로 바뀌므로 쓰기를 거절한다 (11/11 K-21).
  final bool isFrontmatterBroken;

  bool get isDraft => status == NoteStatus.draft;

  static const _known = {
    'id',
    'title',
    'summary',
    'tags',
    'aliases',
    'source',
    'sources',
    'created',
    'updated',
    'status',
  };

  /// md 파일 내용을 읽는다. frontmatter가 없으면 첫 줄 제목을 쓴다.
  static Note parse(
    String text, {
    required String fallbackId,
    required String fallbackTitle,
  }) {
    var meta = <String, Object?>{};
    var body = text;
    var isBroken = false;
    final match = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---\r?\n?').firstMatch(text);
    if (match != null) {
      try {
        final yaml = loadYaml(match.group(1)!);
        if (yaml is YamlMap) {
          meta = {for (final e in yaml.entries) '${e.key}': _plain(e.value)};
        } else if (yaml != null) {
          isBroken = true;
        }
      } on YamlException {
        meta = {};
        isBroken = true;
      }
      body = text.substring(match.end);
    }
    List<String> list(Object? v) => v is List
        ? [for (final x in v) '$x']
        : (v == null || '$v'.isEmpty ? [] : ['$v']);
    return Note(
      id: '${meta['id'] ?? fallbackId}',
      title: toNfc('${meta['title'] ?? fallbackTitle}'),
      summary: '${meta['summary'] ?? ''}',
      tags: list(meta['tags']).map(toNfc).toList(),
      aliases: list(meta['aliases']).map(toNfc).toList(),
      source: '${meta['source'] ?? 'manual'}',
      sources: list(meta['sources']),
      created: DateTime.tryParse('${meta['created'] ?? ''}'),
      updated: DateTime.tryParse('${meta['updated'] ?? ''}'),
      status: NoteStatus.parse(meta['status']),
      body: body,
      extra: {
        for (final e in meta.entries)
          if (!_known.contains(e.key)) e.key: e.value,
      },
      isFrontmatterBroken: isBroken,
    );
  }

  static Object? _plain(Object? value) => switch (value) {
    YamlList() => [for (final v in value) _plain(v)],
    YamlMap() => {for (final e in value.entries) '${e.key}': _plain(e.value)},
    _ => value,
  };

  /// md 파일 내용으로 쓴다. 문자열은 JSON 형식 따옴표(=YAML에서도 유효)로 쓴다.
  String toMarkdown() {
    String q(String s) => jsonEncode(s);
    String l(List<String> xs) => '[${xs.map(q).join(', ')}]';
    final lines = [
      '---',
      'id: $id',
      'title: ${q(title)}',
      'summary: ${q(summary)}',
      'tags: ${l(tags)}',
      'aliases: ${l(aliases)}',
      'source: $source',
      'sources: ${l(sources)}',
      if (created != null) 'created: ${formatTime(created!)}',
      if (updated != null) 'updated: ${formatTime(updated!)}',
      'status: ${status.value}',
      for (final e in extra.entries) '${e.key}: ${jsonEncode(e.value)}',
      '---',
    ];
    final text = body.startsWith('\n') ? body : '\n$body';
    return '${lines.join('\n')}\n${text.trimRight()}\n';
  }

  Note copyWith({
    String? body,
    NoteStatus? status,
    DateTime? updated,
    String? title,
    String? summary,
    List<String>? tags,
    List<String>? aliases,
    Map<String, Object?>? extra,
  }) => Note(
    id: id,
    title: title ?? this.title,
    summary: summary ?? this.summary,
    tags: tags ?? this.tags,
    aliases: aliases ?? this.aliases,
    source: source,
    sources: sources,
    created: created,
    updated: updated ?? this.updated,
    status: status ?? this.status,
    body: body ?? this.body,
    extra: extra ?? this.extra,
    isFrontmatterBroken: isFrontmatterBroken,
  );
}

/// 한국 시간 표기 `2026-11-06T15:00:00+09:00`.
String formatTime(DateTime time) {
  final local = time.toLocal();
  final offset = local.timeZoneOffset;
  String two(int n) => n.abs().toString().padLeft(2, '0');
  final sign = offset.isNegative ? '-' : '+';
  return '${local.year}-${two(local.month)}-${two(local.day)}T'
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}'
      '$sign${two(offset.inHours)}:${two(offset.inMinutes % 60)}';
}
