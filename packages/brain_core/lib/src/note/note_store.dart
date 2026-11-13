import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../log/change_log.dart';
import '../security/secret_mask.dart';
import '../vault/persona.dart';
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

/// 고치는 사이 다른 곳(CLI·AI·편집기)에서 노트가 바뀌었다. 고친 내용은 [copyPath]에 남겼다.
/// 앱은 이것을 보고 [덮어쓰기]·[최신 내용 불러오기]를 보여 준다 (11/11 K-34).
class NoteConflictException extends NoteStoreException {
  const NoteConflictException(super.message, this.copyPath);

  /// 지식 폴더 기준 상대 경로.
  final String copyPath;
}

/// 사용자가 `me.md`에 "저장하면 안 되는 것"으로 적은 말이 들어 있어 저장하지 않았다 (설계서_프롬프트이후 5.2).
/// [term]은 사용자가 쓴 모양 그대로다 — 저장하려던 글에 이미 있던 말이라 AI에게 새로 알려 주는 것이 없다.
class ForbiddenTermException extends NoteStoreException {
  ForbiddenTermException(this.term, this.field)
    : super(
        '저장하지 않았습니다: $field에 "저장하면 안 되는 것"(나에 대해, me.md)으로 정한 "$term"이 있습니다. '
        '그 내용을 빼고 저장하세요. AI는 표현을 바꿔 다시 저장하지 말고 사용자에게 알립니다.',
      );

  final String term;

  /// 제목·요약·본문·태그·별칭 중 어디.
  final String field;
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

  /// 고칠 노트를 읽는다. 노트(`wiki/`)가 아니거나 frontmatter가 깨졌으면 거절한다.
  ///
  /// - 실수 노트·회귀 시험·원본(`raw/`)도 같은 색인에 있어 `brain write L-0001`이나 앱 타임라인의 [고치기]로
  ///   노트처럼 다시 쓰였다. 그러면 승인 대기 규칙이 `status: active`가 되어 모든 세션에 들어갔다 (11/11 K-19).
  /// - frontmatter를 읽지 못한 노트를 다시 쓰면 제목·요약·태그·출처가 기본값으로 바뀐다 (11/11 K-21).
  (IndexedDoc, Note, String) _readForChange(String id) {
    final found = read(id);
    if (found == null) throw NoteStoreException('$id 노트가 없습니다.');
    final (doc, note, _) = found;
    if (doc.kind != 'note') {
      throw NoteStoreException(
        doc.kind == 'raw'
            ? '$id 문서는 원본(raw/)이라 고치지 않습니다. 원본에서 노트를 만들려면 brain add를 쓰세요.'
            : '$id 문서는 실수 노트라 노트처럼 고칠 수 없습니다. 규칙 문장은 brain lesson edit, 상태는 앱의 [배운 것]에서 바꾸세요.',
      );
    }
    if (note.isFrontmatterBroken) {
      throw NoteStoreException(
        '$id 노트의 머리말(frontmatter)을 읽지 못해 고치지 않습니다 (${doc.path}). '
        '편집기로 열어 YAML을 고치세요 — 값에 쌍점(:)이 있으면 큰따옴표로 감쌉니다.',
      );
    }
    return found;
  }

  /// `me.md`의 "저장하면 안 되는 것"이 들어 있으면 [ForbiddenTermException] (설계서_프롬프트이후 5.2).
  /// 기기에서만 검사한다. `me.md`가 있는데 읽지 못하면 막는다 — 금지어를 모른 채 저장하지 않게.
  void checkForbidden({
    required String title,
    required String summary,
    required String body,
    List<String> tags = const [],
    List<String> aliases = const [],
  }) {
    final Persona? persona;
    try {
      persona = Persona.load(vault);
    } on Object catch (e) {
      throw NoteStoreException('me.md(나에 대해)를 읽지 못해 저장하지 않았습니다: $e — 파일을 열어 확인하세요.');
    }
    if (persona == null || persona.forbidden.isEmpty) return;
    final terms = ForbiddenTerms(persona.forbidden);
    for (final (field, text) in [
      ('제목', title),
      ('요약', summary),
      ('본문', body),
      ('태그', tags.join(' , ')),
      ('별칭', aliases.join(' , ')),
    ]) {
      if (terms.find(text) case final term?) throw ForbiddenTermException(term, field);
    }
  }

  /// 다음 노트 번호. 색인과 변경 기록 중 큰 쪽 + 1 — 지운 노트의 번호를 다시 쓰지 않는다 (11/11 K-26).
  String nextNoteId() {
    final max = [
      index.maxNoteNumber(),
      maxLoggedNumber(vault, 'n_'),
    ].reduce((a, b) => a > b ? a : b);
    return 'n_${(max + 1).toString().padLeft(4, '0')}';
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
    checkForbidden(title: cleanTitle, summary: cleanSummary, body: body, tags: tags, aliases: aliases);
    // 번호를 정하고 저장해 색인에 들어갈 때까지 다른 프로세스가 끼어들지 않게 (K-26(다)).
    return withVaultLock(vault, () {
      vault.ensure();
      index.sync();
      final id = nextNoteId();
      final now = DateTime.now();
      final note = Note(
        id: id,
        title: maskSecrets(cleanTitle),
        summary: maskSecrets(cleanSummary),
        tags: [
          for (final t in tags)
            if (t.trim().isNotEmpty) maskSecrets(t.trim()),
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
      appendChangeLog(
        vault,
        'add',
        '$id ${note.status.value} $rel',
        batch: batch,
      );
      _afterChange();
      // 색인에 안 들어갔으면 "저장함"이라고 하지 않는다 (찾을 수 없는 노트, 같은 id 재사용을 막는다).
      if (index.byId(id) == null) {
        throw NoteStoreException(
          '$id를 저장했지만 색인에서 찾지 못했습니다 ($rel). brain index로 다시 맞춘 뒤 확인하세요.',
        );
      }
      return (id, rel);
    });
  }

  /// 본문을 바꾼다. 파일 해시가 기대와 다르면 거절하고 충돌 사본을 남긴다.
  String write(
    String id,
    String newBody, {
    required String expectHash,
    String? batch,
  }) {
    final found = _readForChange(id);
    final (doc, note, hash) = found;
    // 충돌 사본(_meta/conflicts)에도 금지어가 남지 않게 해시보다 먼저 본다.
    checkForbidden(title: note.title, summary: note.summary, body: newBody, tags: note.tags, aliases: note.aliases);
    if (!hash.startsWith(expectHash) || expectHash.length < 6) {
      final conflict = p.join(
        vault.metaDir,
        'conflicts',
        '${id}_${DateTime.now().millisecondsSinceEpoch}.md',
      );
      writeFileAtomic(conflict, maskSecrets(newBody)); // 사본도 지식 폴더 안이다 (11/11 K-31)
      throw NoteConflictException(
        '$id 노트가 그사이 바뀌었습니다 (지금 해시 $hash). 고친 내용은 ${p.relative(conflict, from: vault.root)}에 남겼습니다.',
        p.relative(conflict, from: vault.root),
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
    final found = _readForChange(id);
    final (doc, note, hash) = found;
    checkForbidden(title: title, summary: summary, body: body, tags: tags, aliases: aliases);
    if (hash != expectHash) {
      final conflict = p.join(
        vault.metaDir,
        'conflicts',
        '${id}_${DateTime.now().millisecondsSinceEpoch}.md',
      );
      // 본문만 남기면 고친 제목·요약·태그가 사라졌다 (11/11 K-34). 고치려던 노트 전체를 남기고, 가림도 거친다 (K-31).
      final attempted = note.copyWith(
        title: maskSecrets(title.trim()),
        summary: maskSecrets(summary.trim()),
        tags: [
          for (final t in tags)
            if (t.trim().isNotEmpty) maskSecrets(t.trim()),
        ],
        aliases: [
          for (final a in aliases)
            if (a.trim().isNotEmpty) maskSecrets(a.trim()),
        ],
        body: maskSecrets(body),
      );
      writeFileAtomic(conflict, attempted.toMarkdown());
      throw NoteConflictException(
        '$id 노트가 그사이 다른 곳에서 바뀌었습니다. 고친 내용(제목·요약·태그·본문)은 ${p.relative(conflict, from: vault.root)}에 남겼습니다.',
        p.relative(conflict, from: vault.root),
      );
    }
    final cleanTitle = title.trim();
    final cleanSummary = summary.trim();
    if (cleanTitle.isEmpty) throw const NoteStoreException('제목이 비었습니다.');
    if (cleanSummary.runes.length > 60) {
      throw NoteStoreException(
        '요약 줄은 60자 이내여야 합니다 (지금 ${cleanSummary.runes.length}자).',
      );
    }
    final batchId = batch ?? newBatchId();
    final updated = note.copyWith(
      title: maskSecrets(cleanTitle),
      summary: maskSecrets(cleanSummary),
      // 태그·별칭도 가린다: 앱 편집 화면에서 들어온다 (11/11 K-31)
      tags: [
        for (final t in tags)
          if (t.trim().isNotEmpty) maskSecrets(t.trim()),
      ],
      aliases: [
        for (final a in aliases)
          if (a.trim().isNotEmpty) maskSecrets(a.trim()),
      ],
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

  /// 주제 폴더(뇌)를 만든다. 이미 있으면 그대로 둔다. 반환: 폴더 이름.
  String createTopic(String name) {
    final topic = topicDirName(name);
    Directory(p.join(vault.wikiDir, topic)).createSync(recursive: true);
    appendChangeLog(vault, 'topic-add', topic);
    return topic;
  }

  /// 노트를 다른 주제 폴더로 옮긴다. id·제목이 그대로라 `[[링크]]`는 깨지지 않는다.
  String move(String id, String topic, {String? batch}) {
    final found = _readForChange(id);
    final (doc, note, _) = found;
    final target = topicDirName(topic);
    if (doc.topic == target) return doc.path;
    final batchId = batch ?? newBatchId();
    final from = fileOf(doc);
    final to = uniqueNotePath(p.join(vault.wikiDir, target), note.title);
    recordBeforeChange(vault, from.path, batch: batchId);
    recordBeforeChange(vault, to, batch: batchId);
    Directory(p.dirname(to)).createSync(recursive: true);
    from.renameSync(to);
    final rel = p.relative(to, from: vault.root);
    appendChangeLog(
      vault,
      'move',
      '$id ${doc.topic} → $target',
      batch: batchId,
    );
    _afterChange();
    return rel;
  }

  /// 추천 정리: 연결(직접·추천)의 다수가 다른 주제에 있는 노트를 그 주제로 옮기자고 제안한다.
  /// 노트를 고치지 않고 제안만 돌려준다. (노트 id, 지금 주제, 제안 주제, 근거 연결 수)
  List<(String, String, String, int)> suggestMoves({int minLinks = 2}) {
    index.sync();
    final topicOf = {for (final d in index.notes()) d.id: d.topic};
    final votes = <String, Map<String, int>>{};
    for (final link in index.links()) {
      for (final (a, b) in [
        (link.fromId, link.toId),
        (link.toId, link.fromId),
      ]) {
        final t = topicOf[b];
        if (t == null || !topicOf.containsKey(a)) continue;
        votes
            .putIfAbsent(a, () => {})
            .update(t, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final out = <(String, String, String, int)>[];
    for (final e in votes.entries) {
      final current = topicOf[e.key]!;
      final best = e.value.entries.reduce((a, b) => a.value >= b.value ? a : b);
      final here = e.value[current] ?? 0;
      if (best.key != current && best.value >= minLinks && best.value > here) {
        out.add((e.key, current, best.key, best.value));
      }
    }
    out.sort((a, b) => b.$4.compareTo(a.$4));
    return out;
  }

  /// 노트를 지운다. 실제로는 `_meta/trash/<묶음>/`으로 옮겨서 `brain undo`로 되살릴 수 있다.
  String delete(String id, {String? batch}) {
    final found = _readForChange(id);
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
    final found = _readForChange(id);
    final (doc, note, _) = found;
    recordBeforeChange(vault, fileOf(doc).path, batch: batch);
    writeFileAtomic(
      fileOf(doc).path,
      note.copyWith(status: status, updated: DateTime.now()).toMarkdown(),
    );
    appendChangeLog(
      vault,
      'status',
      '$id ${status.value} ${doc.path}',
      batch: batch,
    );
    _afterChange();
  }

  /// 색인을 맞추고 목차·온보딩 요약을 다시 만든다.
  void _afterChange() {
    index.sync();
    VaultSummary(vault, index).writeAll();
  }
}
