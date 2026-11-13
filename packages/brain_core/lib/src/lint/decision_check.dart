import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../note/note.dart';
import '../note/note_store.dart';
import '../vault/vault.dart';

/// "옛 결정일 수 있음" 짝 한 개 (설계서_프롬프트이후 4.4 (나)): 최근 노트 [newId]와 같은 주제의 더 오래된 비슷한 노트 [oldId].
class DecisionPair {
  const DecisionPair({
    required this.newId,
    required this.oldId,
    required this.newTitle,
    required this.oldTitle,
    required this.topic,
    required this.shared,
  });

  final String newId;
  final String oldId;
  final String newTitle;
  final String oldTitle;
  final String topic;

  /// 새 노트 핵심 단어 5개 중 옛 노트에 나오는 수.
  final int shared;

  /// 순서와 상관없는 짝 열쇠 ([둘 다 맞음] 기억용).
  String get key => ([newId, oldId]..sort()).join('|');

  Map<String, Object> toJson() => {
    'new': newId,
    'old': oldId,
    'newTitle': newTitle,
    'oldTitle': oldTitle,
    'topic': topic,
    'shared': shared,
  };

  static DecisionPair fromJson(Map<String, dynamic> json) => DecisionPair(
    newId: '${json['new']}',
    oldId: '${json['old']}',
    newTitle: '${json['newTitle'] ?? ''}',
    oldTitle: '${json['oldTitle'] ?? ''}',
    topic: '${json['topic'] ?? ''}',
    shared: (json['shared'] as num?)?.toInt() ?? 0,
  );
}

/// 주 1회 옛 결정 점검 (설계서_프롬프트이후 4.4 (나)). AI 호출 없이 비슷한 노트 점수로만 짝짓는다.
///
/// 상태는 `_meta/decision_check.json` 하나: 마지막 점검 시각, 지난 점검이 찾은 짝, [둘 다 맞음]을 누른 짝.
/// 찾은 짝을 남기는 이유: 앱을 다시 켜도 다음 점검(7일 뒤)까지 카드가 남아야 한다.
class DecisionCheck {
  DecisionCheck(this.vault, this.index);

  final Vault vault;
  final SearchIndex index;

  /// 최근 며칠에 만들거나 고친 노트를 보나.
  static const recentDays = 7;

  /// 앱이 저절로 다시 점검하는 간격.
  static const interval = Duration(days: 7);

  File get _file => File(p.join(vault.metaDir, 'decision_check.json'));

  Map<String, dynamic> _load() {
    try {
      return jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
    } on Object {
      return {}; // 없거나 깨졌으면 처음 점검처럼 (짝이 다시 보일 뿐 노트는 안전하다)
    }
  }

  void _save({DateTime? lastRun, List<DecisionPair>? pairs, Set<String>? kept}) {
    final state = _load();
    writeFileAtomic(
      _file.path,
      const JsonEncoder.withIndent('  ').convert({
        'lastRun': lastRun?.toIso8601String() ?? state['lastRun'],
        'pairs': pairs == null ? (state['pairs'] ?? const []) : [for (final x in pairs) x.toJson()],
        'kept': kept == null ? (state['kept'] ?? const []) : ([...kept]..sort()),
      }),
    );
  }

  DateTime? get lastRun => DateTime.tryParse('${_load()['lastRun'] ?? ''}');

  Set<String> get _kept => {for (final k in (_load()['kept'] as List? ?? const [])) '$k'};

  /// 마지막 점검에서 [interval]이 지났나 (한 번도 안 돌았으면 true).
  bool isDue({DateTime? now}) {
    final last = lastRun;
    return last == null || (now ?? DateTime.now()).difference(last) >= interval;
  }

  /// 지난 점검이 찾은 짝 중 아직 물어볼 것: 두 노트가 다 정리됨이고 [둘 다 맞음]을 누르지 않았다.
  List<DecisionPair> pending() {
    final kept = _kept;
    return [
      for (final raw in (_load()['pairs'] as List? ?? const []))
        if (DecisionPair.fromJson(raw as Map<String, dynamic>) case final pair
            when !kept.contains(pair.key) && _isActive(pair.newId) && _isActive(pair.oldId))
          pair,
    ];
  }

  bool _isActive(String id) => index.byId(id)?.status == NoteStatus.active;

  /// 최근 [recentDays]일에 만들거나 고친 정리된 노트마다 같은 주제의 더 오래된 비슷한 노트를 짝짓고 저장한다.
  /// [onProgress]는 (본 노트 수, 볼 노트 수). 노트 1만 개에서도 최근 노트만 파일을 읽는다.
  List<DecisionPair> run({DateTime? now, void Function(int done, int total)? onProgress}) {
    final at = now ?? DateTime.now();
    final since = at.subtract(const Duration(days: recentDays));
    index.sync();
    final kept = _kept;
    // 파일 시각으로 먼저 거른다: 고치지 않은 노트는 파일 시각도 오래됐다. 그다음 머리말의 날짜로 정확히 본다.
    final candidates = [
      for (final doc in index.notes())
        if (doc.status == NoteStatus.active && doc.mtime.isAfter(since)) doc,
    ];
    final createdCache = <String, DateTime>{};
    DateTime? createdOf(IndexedDoc doc, [Note? note]) {
      final cached = createdCache[doc.id];
      if (cached != null) return cached;
      final n = note ?? _readNote(doc);
      if (n == null) return null;
      return createdCache[doc.id] = n.created ?? n.updated ?? doc.mtime;
    }

    // 머리말의 날짜로 최근 노트를 먼저 추린다: 진행 표시의 전체 수가 실제로 볼 노트 수가 되게.
    final recent = <(IndexedDoc, Note)>[];
    for (final doc in candidates) {
      final note = _readNote(doc);
      if (note == null) continue;
      if ((note.updated ?? note.created ?? doc.mtime).isBefore(since)) continue;
      recent.add((doc, note));
    }
    final pairs = <String, DecisionPair>{};
    for (final (i, (doc, note)) in recent.indexed) {
      onProgress?.call(i, recent.length);
      final created = createdOf(doc, note)!;
      for (final similar in index.similarNotes(
        note,
        excludeId: doc.id,
        topic: doc.topicPath,
        minShared: SearchIndex.similarStrongMin,
      )) {
        final other = similar.doc;
        final otherCreated = createdOf(other);
        if (otherCreated == null || !otherCreated.isBefore(created)) continue; // 더 오래된 노트만 옛 결정 후보
        final pair = DecisionPair(
          newId: doc.id,
          oldId: other.id,
          newTitle: doc.title,
          oldTitle: other.title,
          topic: doc.topicPath,
          shared: similar.shared,
        );
        if (kept.contains(pair.key)) continue;
        final existing = pairs[pair.key];
        if (existing == null || existing.shared < pair.shared) pairs[pair.key] = pair;
      }
    }
    onProgress?.call(recent.length, recent.length);
    final found = pairs.values.toList()..sort((a, b) => b.shared.compareTo(a.shared));
    _save(lastRun: at, pairs: found);
    return found;
  }

  Note? _readNote(IndexedDoc doc) {
    final file = File(p.join(vault.root, doc.path));
    try {
      return Note.parse(file.readAsStringSync(), fallbackId: doc.id, fallbackTitle: doc.title);
    } on FileSystemException {
      return null; // 그사이 지워졌거나 읽을 수 없는 파일은 건너뛴다
    }
  }

  /// [둘 다 맞음]: 이 짝은 다시 묻지 않는다.
  void keepBoth(DecisionPair pair) {
    final kept = _kept..add(pair.key);
    _save(kept: kept, pairs: [for (final x in pending()) if (x.key != pair.key) x]);
  }

  /// [옛 노트 보관]: 옛 노트를 "합쳐짐"으로 바꾸고 새 노트를 가리키게 한다 (지우지 않음, 되돌리기 묶음 하나).
  void archiveOld(NoteStore store, DecisionPair pair, {String? batch}) {
    store.markMerged(pair.oldId, into: pair.newId, batch: batch);
    _save(pairs: [for (final x in pending()) if (x.key != pair.key) x]);
  }
}
