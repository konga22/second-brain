import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../log/change_log.dart';
import '../security/secret_mask.dart';
import '../vault/vault.dart';
import 'file_name.dart';
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
    writeFileAtomic(path, note.toMarkdown());
    final rel = p.relative(path, from: vault.root);
    appendChangeLog(vault, 'add', '$id ${note.status.value} $rel');
    index.sync();
    return (id, rel);
  }

  /// 본문을 바꾼다. 파일 해시가 기대와 다르면 거절하고 충돌 사본을 남긴다.
  String write(String id, String newBody, {required String expectHash}) {
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
    writeFileAtomic(fileOf(doc).path, content);
    appendChangeLog(vault, 'write', '$id ${doc.path}');
    index.sync();
    return contentHash(content);
  }

  /// 정리 대기 → 정리됨 같은 상태 바꾸기.
  void setStatus(String id, NoteStatus status) {
    final found = read(id);
    if (found == null) throw NoteStoreException('$id 노트가 없습니다.');
    final (doc, note, _) = found;
    writeFileAtomic(
      fileOf(doc).path,
      note.copyWith(status: status, updated: DateTime.now()).toMarkdown(),
    );
    appendChangeLog(vault, 'status', '$id ${status.value} ${doc.path}');
    index.sync();
  }
}
