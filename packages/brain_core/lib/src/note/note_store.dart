import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../log/change_log.dart';
import '../security/secret_mask.dart';
import '../vault/vault.dart';
import '../vault/vault_summary.dart';
import 'file_name.dart';
import 'wiki_links.dart';
import 'note.dart';

class NoteStoreException implements Exception {
  const NoteStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 노트 읽기·쓰기. 모든 쓰기는 형식 검사·비밀값 가림·원자적 쓰기·변경 기록을 거친다.
class NoteStore {
  NoteStore(this.vault, this.index);

  final Vault vault;
  final SearchIndex index;

  File fileOf(IndexedDoc doc) => File(p.join(vault.root, doc.path));

  (IndexedDoc, Note, String)? read(String id) {
    index.sync();
    final doc = index.byId(id);
    if (doc == null) return null;
    final file = fileOf(doc);
    if (!file.existsSync()) return null;
    final content = file.readAsStringSync();
    final note = Note.parse(
      content,
      fallbackId: doc.id,
      fallbackTitle: doc.title,
    );
    return (doc, note, contentHash(content));
  }

  /// 새 노트를 만든다. 반환: (id, 지식 폴더 기준 경로).
  (String, String) add({
    required String title,
    required String body,
    required String summary,
    List<String> tags = const [],
    String? topic,
    bool draft = false,
    String source = 'manual',
    List<String> sources = const [],
    List<String> aliases = const [],
    String? batch,
  }) {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      throw const NoteStoreException('제목이 비었습니다 (--title).');
    }
    final cleanSummary = summary.trim();
    if (cleanSummary.isEmpty) {
      throw const NoteStoreException('요약 줄이 비었습니다 (--summary, 60자 이내).');
    }
    if (cleanSummary.runes.length > 60) {
      throw NoteStoreException(
        '요약 줄은 60자 이내여야 합니다 (지금 ${cleanSummary.runes.length}자).',
      );
    }
    if (body.trim().isEmpty) {
      throw const NoteStoreException('본문이 비었습니다 (표준 입력).');
    }
    vault.ensure();
    index.sync();
    final id = 'n_${(index.maxNoteNumber() + 1).toString().padLeft(4, '0')}';
    final now = DateTime.now();
    final note = Note(
      id: id,
      title: maskSecrets(cleanTitle),
      summary: maskSecrets(cleanSummary),
      tags: [
        for (final t in tags)
          if (t.trim().isNotEmpty) t.trim(),
      ],
      aliases: [
        for (final a in aliases)
          if (a.trim().isNotEmpty) maskSecrets(a.trim()),
      ],
      source: source,
      sources: sources,
      created: now,
      updated: now,
      status: draft ? NoteStatus.draft : NoteStatus.active,
      body: maskSecrets(body),
    );
    final dir = p.join(
      vault.wikiDir,
      topicDirName(topic ?? (note.tags.isEmpty ? null : note.tags.first)),
    );
    final path = uniqueNotePath(dir, note.title);
    recordBeforeChange(vault, path, batch: batch);
    writeFileAtomic(path, note.toMarkdown());
    final rel = p.relative(path, from: vault.root);
    appendChangeLog(vault, 'add', '$id ${note.status.value} $rel', batch: batch);
    _afterChange();
    return (id, rel);
  }

  /// 본문을 바꾼다. 파일 해시가 기대와 다르면 거절하고 충돌 사본을 남긴다.
  String write(
    String id,
    String newBody, {
    required String expectHash,
    String? batch,
  }) {
    final found = read(id);
    if (found == null) throw NoteStoreException('$id 노트가 없습니다.');
    final (doc, note, hash) = found;
    if (!hash.startsWith(expectHash) || expectHash.length < 6) {
      final conflict = p.join(
        vault.metaDir,
        'conflicts',
        '${id}_${DateTime.now().millisecondsSinceEpoch}.md',
      );
      writeFileAtomic(conflict, newBody);
      throw NoteStoreException(
        '$id 노트가 그사이 바뀌었습니다 (지금 해시 $hash). 고친 내용은 ${p.relative(conflict, from: vault.root)}에 남겼습니다.',
      );
    }
    final updated = note.copyWith(
      body: maskSecrets(newBody),
      updated: DateTime.now(),
    );
    final content = updated.toMarkdown();
    recordBeforeChange(vault, fileOf(doc).path, batch: batch);
    writeFileAtomic(fileOf(doc).path, content);
    appendChangeLog(vault, 'write', '$id ${doc.path}', batch: batch);
    _afterChange();
    return contentHash(content);
  }

  /// 앱 편집 화면: 제목·요약·태그·별칭·본문을 한 번에 고친다. 해시가 다르면 거절(충돌 사본).
  ///
  /// 제목이 바뀌면 파일 이름을 바꾸고, 이 노트를 `[[옛 제목]]`으로 가리키던 노트의 링크도 고친다.
  /// 반환: 새 해시.
  String update(
    String id, {
    required String expectHash,
    required String title,
    required String summary,
    required String body,
    List<String> tags = const [],
    List<String> aliases = const [],
    String? batch,
  }) {
    final found = read(id);
    if (found == null) throw NoteStoreException('$id 노트가 없습니다.');
    final (doc, note, hash) = found;
    if (hash != expectHash) {
      final conflict = p.join(
        vault.metaDir,
        'conflicts',
        '${id}_${DateTime.now().millisecondsSinceEpoch}.md',
      );
      writeFileAtomic(conflict, body);
      throw NoteStoreException(
        '$id 노트가 그사이 다른 곳에서 바뀌었습니다. 고친 본문은 ${p.relative(conflict, from: vault.root)}에 남겼습니다.',
      );
    }
    final cleanTitle = title.trim();
    final cleanSummary = summary.trim();
    if (cleanTitle.isEmpty) throw const NoteStoreException('제목이 비었습니다.');
    if (cleanSummary.runes.length > 60) {
      throw NoteStoreException('요약 줄은 60자 이내여야 합니다 (지금 ${cleanSummary.runes.length}자).');
    }
    final batchId = batch ?? newBatchId();
    final updated = note.copyWith(
      title: maskSecrets(cleanTitle),
      summary: maskSecrets(cleanSummary),
      tags: [for (final t in tags) if (t.trim().isNotEmpty) t.trim()],
      aliases: [for (final a in aliases) if (a.trim().isNotEmpty) a.trim()],
      body: maskSecrets(body),
      updated: DateTime.now(),
    );
    final oldFile = fileOf(doc);
    var path = oldFile.path;
    final isRenamed = linkKey(updated.title) != linkKey(note.title);
    // 이름을 바꾸면 옛 제목 링크가 끊기므로, 바꾸기 전에 이 노트를 가리키는 노트를 모은다.
    final linking = isRenamed
        ? {
            for (final link in index.links())
              if (!link.isSuggested && link.toId == id) link.fromId,
          }
        : const <String>{};
    if (isRenamed) {
      path = uniqueNotePath(p.dirname(oldFile.path), updated.title);
    }
    recordBeforeChange(vault, oldFile.path, batch: batchId);
    if (isRenamed) recordBeforeChange(vault, path, batch: batchId);
    final content = updated.toMarkdown();
    writeFileAtomic(path, content);
    if (isRenamed) {
      oldFile.deleteSync();
      _relinkTitle(linking, note.title, updated.title, batchId);
    }
    appendChangeLog(
      vault,
      isRenamed ? 'rename' : 'update',
      '$id ${p.relative(path, from: vault.root)}',
      batch: batchId,
    );
    _afterChange();
    return contentHash(content);
  }

  /// `[[옛 제목]]`·`[[옛 제목|글]]`·`[[옛 제목#섹션]]`을 새 제목으로 바꾼다.
  void _relinkTitle(
    Set<String> fromIds,
    String oldTitle,
    String newTitle,
    String batch,
  ) {
    final oldKey = linkKey(oldTitle);
    for (final fromId in fromIds) {
      final from = index.byId(fromId);
      if (from == null) continue;
      final file = fileOf(from);
      final text = file.readAsStringSync();
      final changed = text.replaceAllMapped(
        RegExp(r'\[\[([^\[\]\n|#]+)([|#][^\[\]\n]*)?\]\]'),
        (m) => linkKey(m.group(1)!) == oldKey
            ? '[[$newTitle${m.group(2) ?? ''}]]'
            : m.group(0)!,
      );
      if (changed == text) continue;
      recordBeforeChange(vault, file.path, batch: batch);
      writeFileAtomic(file.path, changed);
      appendChangeLog(vault, 'relink', '${from.id} → $newTitle', batch: batch);
    }
  }

  /// 노트를 지운다. 실제로는 `_meta/trash/<묶음>/`으로 옮겨서 `brain undo`로 되살릴 수 있다.
  String delete(String id, {String? batch}) {
    final found = read(id);
    if (found == null) throw NoteStoreException('$id 노트가 없습니다.');
    final (doc, _, _) = found;
    final batchId = batch ?? newBatchId();
    final file = fileOf(doc);
    recordBeforeChange(vault, file.path, batch: batchId);
    final trash = p.join(vault.metaDir, 'trash', batchId, doc.path);
    Directory(p.dirname(trash)).createSync(recursive: true);
    file.renameSync(trash);
    appendChangeLog(vault, 'delete', '$id ${doc.path}', batch: batchId);
    _afterChange();
    return batchId;
  }

  /// 정리 대기 → 정리됨 같은 상태 바꾸기.
  void setStatus(String id, NoteStatus status, {String? batch}) {
    final found = read(id);
    if (found == null) throw NoteStoreException('$id 노트가 없습니다.');
    final (doc, note, _) = found;
    recordBeforeChange(vault, fileOf(doc).path, batch: batch);
    writeFileAtomic(
      fileOf(doc).path,
      note.copyWith(status: status, updated: DateTime.now()).toMarkdown(),
    );
    appendChangeLog(vault, 'status', '$id ${status.value} ${doc.path}', batch: batch);
    _afterChange();
  }

  /// 색인을 맞추고 목차·온보딩 요약을 다시 만든다.
  void _afterChange() {
    index.sync();
    VaultSummary(vault, index).writeAll();
  }
}
