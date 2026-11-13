import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../note/note.dart';
import '../note/note_store.dart';
import '../vault/vault.dart';
import '../vault/vault_summary.dart';
import 'change_history.dart';
import 'change_log.dart';

/// AI가 고친 정리된 노트 한 개 (설계서_프롬프트이후 4.3). 같은 노트를 여러 번 고쳤으면 한 카드로 묶는다.
class AiEdit {
  const AiEdit({
    required this.noteId,
    required this.title,
    required this.batches,
    required this.firstAt,
    required this.lastAt,
    required this.sessions,
    required this.canRevert,
  });

  final String noteId;
  final String title;

  /// 이 노트를 고친 AI 작업 묶음 (오래된 순). [되돌리기]는 이것을 최근 것부터 되돌린다.
  final List<String> batches;
  final DateTime firstAt;
  final DateTime lastAt;

  /// 고친 AI 대화 id (모르면 비어 있음).
  final Set<String> sessions;

  /// AI가 고친 뒤 사람(앱·터미널)이 또 고쳤으면 false: 되돌리면 사람의 고침까지 사라진다.
  final bool canRevert;
}

/// 정리 보드 "AI가 고친 노트" (설계서_프롬프트이후 4.3).
///
/// 변경 기록(`_log/`)의 AI 표시 줄과 되돌리기 묶음(`_meta/undo/`)으로 만든다. 새로 저장하는 것은
/// [확인함]을 누른 묶음 목록(`_meta/ai_edits_seen.json`)뿐이다.
class AiEditReview {
  AiEditReview(this.vault, this.index);

  final Vault vault;
  final SearchIndex index;

  static const _edits = {'write', 'update', 'rename'};

  /// 노트 내용을 바꾸는 기록 (AI가 고친 뒤 이런 기록이 사람 쪽에서 있으면 되돌리지 않는다).
  static const _changes = {'write', 'update', 'rename', 'status', 'move', 'merge', 'lint-fix', 'relink'};

  File get _seenFile => File(p.join(vault.metaDir, 'ai_edits_seen.json'));

  Set<String> _seen() {
    try {
      final json = jsonDecode(_seenFile.readAsStringSync()) as Map<String, dynamic>;
      return {for (final b in (json['batches'] as List? ?? const [])) '$b'};
    } on Object {
      return {}; // 없거나 깨졌으면 처음부터 (카드가 다시 보일 뿐 노트는 안전하다)
    }
  }

  /// 아직 되돌리지 않은 묶음 폴더. 되돌린 묶음은 이름이 바뀌어(`-u<시각>`) 없다.
  Directory? _batchDir(String batch) {
    if (!batchIdPattern.hasMatch(batch)) return null;
    final dir = Directory(p.join(vault.metaDir, 'undo', batch));
    if (!File(p.join(dir.path, 'manifest.jsonl')).existsSync()) return null;
    if (File(p.join(dir.path, 'undone')).existsSync()) return null;
    return dir;
  }

  /// 확인하지 않은 AI 고침 (최근 고친 순). 지금 정리된(active) 노트만: 초안은 정리 대기에서 본다.
  List<AiEdit> pending({int months = 3}) {
    final events = readChangeHistory(vault, months: months).reversed.toList(); // 오래된 순
    final seen = _seen();
    final byNote = <String, List<ChangeEvent>>{};
    for (final e in events) {
      if (!e.isAi || !_edits.contains(e.action)) continue;
      final id = e.targetId;
      if (id == null || !id.startsWith('n_')) continue;
      if (seen.contains(e.batch) || _batchDir(e.batch) == null) continue;
      byNote.putIfAbsent(id, () => []).add(e);
    }
    final out = <AiEdit>[];
    for (final MapEntry(key: id, value: edits) in byNote.entries) {
      final doc = index.byId(id);
      if (doc == null || doc.kind != 'note' || doc.status != NoteStatus.active) continue;
      final first = edits.first.at;
      final batches = {for (final e in edits) e.batch};
      final humanAfter = events.any(
        (e) => !e.isAi && e.targetId == id && _changes.contains(e.action) && !e.at.isBefore(first) && !batches.contains(e.batch),
      );
      out.add(
        AiEdit(
          noteId: id,
          title: doc.title,
          batches: batches.toList(),
          firstAt: first,
          lastAt: edits.last.at,
          sessions: {for (final e in edits) if (e.aiSession != null) e.aiSession!},
          canRevert: !humanAfter,
        ),
      );
    }
    out.sort((a, b) => b.lastAt.compareTo(a.lastAt));
    return out;
  }

  /// [바뀐 내용 보기]: (AI가 처음 고치기 전 본문, 지금 본문). 고치기 전 사본을 못 찾으면 앞은 null.
  (String?, String) beforeAfter(AiEdit edit) {
    final current = NoteStore(vault, index).read(edit.noteId)?.$2.body ?? '';
    final dir = _batchDir(edit.batches.first);
    if (dir == null) return (null, current);
    for (final line in File(p.join(dir.path, 'manifest.jsonl')).readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final entry = jsonDecode(line) as Map<String, dynamic>;
      final backup = entry['backup'] as String?;
      if (entry['existed'] != true || backup == null) continue;
      final file = File(p.join(dir.path, backup));
      if (!file.existsSync()) continue;
      final note = Note.parse(file.readAsStringSync(), fallbackId: '', fallbackTitle: '');
      if (note.id == edit.noteId) return (note.body, current);
    }
    return (null, current);
  }

  /// [확인함]: 이 고침을 봤다고 남긴다. 파일은 그대로다.
  void acknowledge(AiEdit edit) {
    final seen = _seen()..addAll(edit.batches);
    writeFileAtomic(_seenFile.path, jsonEncode({'batches': [...seen]..sort()}));
  }

  /// [되돌리기]: 이 노트를 고친 AI 묶음을 최근 것부터 되돌린다 (`brain undo`와 같다). 반환: 되돌린 파일 수.
  /// 한 묶음에 다른 파일(제목을 바꿀 때 고친 링크)이 있으면 함께 돌아간다.
  ///
  /// 11/13 검토: 이 노트의 사람 기록만 보고 묶음을 통째로 되살려, 같은 묶음에서 바뀐 다른 노트의 뒤 고침과 편집기로 고친
  /// 내용(기록이 남지 않음)까지 지웠다. 화면에 뜬 [edit]도 오래됐을 수 있다. 그래서 (설계서_프롬프트이후 4.3)
  /// 1. 카드를 지금 기록으로 다시 만들어 본다 (그사이 사람이 고쳤거나, 새 AI 고침이 생겼으면 멈춤)
  /// 2. 묶음이 바꾼 파일이 모두 AI가 남긴 그대로인지 먼저 다 본다 ([driftSinceBatches]). 하나라도 다르면 아무것도 되돌리지 않는다
  /// 3. 그다음에만 되돌리고, 도중에 실패해도 색인·목차는 맞춘다
  int revert(AiEdit edit) {
    final fresh = pending().where((e) => e.noteId == edit.noteId).firstOrNull;
    if (fresh == null) {
      throw NoteStoreException('${edit.noteId} 노트의 AI 고침은 이미 되돌렸거나 [확인함]으로 넘겼습니다. 정리 보드를 다시 보세요.');
    }
    if (!fresh.canRevert) {
      throw NoteStoreException(
        '${edit.noteId} 노트는 AI가 고친 뒤 직접 고친 기록이 있어 되돌리지 않습니다 (직접 고친 내용까지 사라짐). '
        '[바뀐 내용 보기]로 보고 직접 고치세요.',
      );
    }
    if (!_sameSet(fresh.batches, edit.batches)) {
      throw NoteStoreException('${edit.noteId} 노트를 AI가 그사이 또 고쳤습니다. 정리 보드를 다시 보고 [바뀐 내용 보기]로 확인한 뒤 되돌리세요.');
    }
    final batches = [
      for (final batch in fresh.batches.reversed)
        if (_batchDir(batch) != null) batch,
    ];
    final drift = driftSinceBatches(vault, batches);
    if (drift.isNotEmpty) {
      final changed = [for (final d in drift) if (!d.isUnknown) _describe(d.path)];
      final unknown = [for (final d in drift) if (d.isUnknown) _describe(d.path)];
      throw NoteStoreException(
        changed.isNotEmpty
            ? '되돌리지 않았습니다: AI가 고친 뒤 ${changed.join(', ')}이(가) 다른 곳(앱·터미널·편집기·다른 AI 작업)에서 또 바뀌었습니다. '
                  '되돌리면 그 고침까지 사라집니다. [바뀐 내용 보기]로 보고 직접 고치세요.'
            : '되돌리지 않았습니다: ${unknown.join(', ')}은(는) 고친 뒤 상태를 남기기 전(11/13 전)의 기록이라 그사이 바뀌었는지 확인할 수 없습니다. '
                  '[바뀐 내용 보기]로 보고 직접 고치세요.',
      );
    }
    var count = 0;
    try {
      for (final batch in batches) {
        count += undoBatch(vault, batch);
      }
    } finally {
      index.sync();
      VaultSummary(vault, index).writeAll();
    }
    return count;
  }

  /// 바뀐 파일을 사람이 알아볼 이름으로: `n_0002 릴리스 절차 (wiki/…)`. 노트가 아니거나 없으면 경로만.
  String _describe(String rel) {
    try {
      final file = File(p.join(vault.root, rel));
      if (file.existsSync() && rel.endsWith('.md')) {
        final note = Note.parse(file.readAsStringSync(), fallbackId: '', fallbackTitle: '');
        if (note.id.isNotEmpty) return '${note.id} ${note.title} ($rel)';
      }
    } on Object {
      // 읽지 못하면 경로만 보인다
    }
    return rel;
  }
}

bool _sameSet(List<String> a, List<String> b) => a.toSet().containsAll(b) && b.toSet().containsAll(a);
