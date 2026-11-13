import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../log/change_log.dart';
import '../security/secret_mask.dart';
import '../vault/persona.dart';
import '../vault/vault.dart';
import '../vault/vault_summary.dart';
import 'file_name.dart';
import 'note_assets.dart';
import 'wiki_links.dart';
import 'note.dart';
import 'zones.dart';

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

/// 폴더 정리 한 줄 (설계서_프롬프트이후 5.1): 노트 [id]를 [topic](`구역/주제`)으로, 파일 이름은 [name](없으면 짧은 이름).
class FolderMove {
  const FolderMove({required this.id, required this.topic, this.name});

  final String id;
  final String topic;
  final String? name;
}

/// 옮긴 노트 하나: 지식 폴더 기준 옛 경로 → 새 경로.
typedef MovedNote = ({String id, String from, String to});

/// 옮기지 못한 줄 하나와 까닭.
typedef MoveError = ({String id, String message});

class MoveResult {
  const MoveResult({required this.batch, required this.moved, required this.errors});

  final String batch;
  final List<MovedNote> moved;
  final List<MoveError> errors;
}

/// 노트 읽기·쓰기. 모든 쓰기는 형식 검사·비밀값 가림·원자적 쓰기·변경 기록을 거친다.
class NoteStore {
  /// [zoned]: 새 노트를 구역 안(`wiki/<구역>/<주제>/<짧은 이름>.md`)에 둔다 (설계서_프롬프트이후 5.1).
  /// 주지 않으면 설정의 "이전 방식"(5.1 폴더 구조, `BRAIN_LEGACY=folders`)을 따른다 — 앱·CLI·백그라운드 작업이
  /// 따로 정하지 않아도 같은 방식으로 저장하게.
  NoteStore(this.vault, this.index, {bool? zoned})
    : isZoned = zoned ?? !AppConfig.load().usesLegacy(AppConfig.legacyFolders);

  final Vault vault;
  final SearchIndex index;

  /// 새 노트·옮기기 대상에 구역을 쓰는가 (false = 이전 방식 `wiki/<주제>/<제목>.md`).
  final bool isZoned;

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
    List<String> attachments = const [],
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
    // 구역은 아무것도 쓰기 전에 본다: 모르는 구역이면 노트도 사진도 남기지 않는다 (설계서_프롬프트이후 5.1).
    final topicPath = isZoned && topic != null ? resolveTopicPath(topic, index.zoneTopics) : null;
    // 사진은 아무것도 쓰기 전에 모두 검사한다: 하나라도 틀리면 노트도 사진도 남기지 않는다 (설계서_프롬프트이후 5.5).
    for (final path in attachments) {
      checkAttachment(path);
    }
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
      final String path;
      if (isZoned) {
        // 구역을 안 고르면(사람이 앱·터미널에서) 구역 밖 `미분류`에 둔다 — [폴더 정리]에 나와 나중에 고른다.
        // AI 저장은 `brain add`가 --topic 없이는 받지 않는다.
        path = uniqueNotePath(p.join(vault.wikiDir, topicPath ?? '미분류'), shortNoteName(note.title));
      } else {
        final dir = p.join(
          vault.wikiDir,
          topicDirName(legacyTopicName(topic) ?? (note.tags.isEmpty ? null : note.tags.first)),
        );
        path = uniqueNotePath(dir, note.title);
      }
      // 사진 링크는 가림을 거친 본문 뒤에 붙인다: 노트 폴더 기준 상대 경로라 파일 자리가 정해진 뒤에 만든다.
      final assets = <String, bool>{}; // 경로 → 새로 만들었는가
      final links = <String>[];
      for (final source in attachments) {
        final (assetRel, isNew) = storeAsset(vault, source, batch: batch);
        if (assets.containsKey(assetRel)) continue; // 같은 사진 두 번 → 링크 하나
        assets[assetRel] = isNew;
        links.add(assetLink(vault, path, assetRel, p.basename(source)));
      }
      final saved = links.isEmpty ? note : note.copyWith(body: '${note.body.trimRight()}\n\n${links.join('\n\n')}\n');
      recordBeforeChange(vault, path, batch: batch);
      writeFileAtomic(path, saved.toMarkdown());
      final rel = p.relative(path, from: vault.root);
      appendChangeLog(
        vault,
        'add',
        '$id ${note.status.value} $rel',
        batch: batch,
      );
      for (final MapEntry(key: assetRel, value: isNew) in assets.entries) {
        appendChangeLog(vault, 'attach', '$id $assetRel ${isNew ? '새 파일' : '이미 있음'}', batch: batch);
      }
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
  ///
  /// 지식 폴더 잠금 안에서 읽고·견주고·쓴다 (설계서_프롬프트이후 5.1, 11/13 검토): [폴더 정리]가 옮기는 사이에 옛 경로로
  /// 쓰면 옛 자리에 같은 노트가 다시 생겼다. 잠금 안에서 다시 읽으므로 옮긴 뒤면 새 자리를 고친다.
  String write(
    String id,
    String newBody, {
    required String expectHash,
    String? batch,
  }) => withVaultLock(vault, () {
    final found = _readForChange(id);
    final (doc, note, hash) = found;
    // 충돌 사본(_meta/conflicts)에도 금지어가 남지 않게 해시보다 먼저 본다. 새로 쓰는 본문만 본다:
    // 금지어를 나중에 더하면 제목에 든 옛 노트는 깨끗한 본문으로도 못 고쳤다 (11/13 검토).
    checkForbidden(title: '', summary: '', body: newBody);
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
  });

  /// 앱 편집 화면: 제목·요약·태그·별칭·본문을 한 번에 고친다. 해시가 다르면 거절(충돌 사본).
  ///
  /// 제목이 바뀌면 파일 이름을 바꾸고, 이 노트를 `[[옛 제목]]`으로 가리키던 노트의 링크도 고친다.
  /// 반환: 새 해시. 잠금 안에서 읽고 쓴다 (위 [write]와 같은 까닭, 11/13 검토).
  String update(
    String id, {
    required String expectHash,
    required String title,
    required String summary,
    required String body,
    List<String> tags = const [],
    List<String> aliases = const [],
    String? batch,
  }) => withVaultLock(vault, () {
    final found = _readForChange(id);
    final (doc, note, hash) = found;
    // 바뀌는 칸만 본다 (위 write와 같은 까닭).
    checkForbidden(
      title: title == note.title ? '' : title,
      summary: summary == note.summary ? '' : summary,
      body: body == note.body ? '' : body,
      tags: _sameList(tags, note.tags) ? const [] : tags,
      aliases: _sameList(aliases, note.aliases) ? const [] : aliases,
    );
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
      // 구역 안 노트는 짧은 이름 (설계서_프롬프트이후 5.1). 짧은 이름이 지금과 같으면 파일 이름은 그대로다.
      path = uniqueNotePath(
        p.dirname(oldFile.path),
        doc.zone != null ? shortNoteName(updated.title) : updated.title,
        self: oldFile.path,
      );
    }
    recordBeforeChange(vault, oldFile.path, batch: batchId);
    if (isRenamed) recordBeforeChange(vault, path, batch: batchId);
    final content = updated.toMarkdown();
    writeFileAtomic(path, content);
    if (isRenamed && path != oldFile.path) oldFile.deleteSync();
    if (isRenamed) {
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
  });

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

  /// 주제 폴더(뇌)를 만든다. 이미 있으면 그대로 둔다. 반환: wiki 기준 주제 경로.
  /// 구역을 쓰면 `구역/주제`로 받는다 — 구역 자체는 만들지 않는다 (설계서_프롬프트이후 5.1).
  String createTopic(String name) {
    final topic = isZoned || name.contains('/') ? resolveTopicPath(name, index.zoneTopics) : topicDirName(name);
    Directory(p.join(vault.wikiDir, topic)).createSync(recursive: true);
    appendChangeLog(vault, 'topic-add', topic);
    return topic;
  }

  /// 노트를 다른 주제 폴더로 옮긴다. id·제목이 그대로라 `[[링크]]`는 깨지지 않는다. 반환: 새 경로.
  /// [topic]은 `구역/주제`(이전 방식이면 `주제`도). 파일 이름은 [name], 없으면 구역 안에서는 짧은 이름.
  String move(String id, String topic, {String? name, String? batch}) {
    final result = moveMany([FolderMove(id: id, topic: topic, name: name)], batch: batch);
    if (result.errors.isNotEmpty) throw NoteStoreException(result.errors.first.message);
    return result.moved.isEmpty ? index.byId(id)!.path : result.moved.single.to;
  }

  /// 여러 노트를 한 되돌리기 묶음으로 옮긴다 (설계서_프롬프트이후 5.1 [폴더 정리]). 틀린 줄은 [MoveResult.errors]에
  /// 남기고 나머지는 옮긴다. [onProgress]는 줄마다 (끝낸 수, 전체).
  ///
  /// - 색인은 처음에 한 번, 끝에 한 번만 맞춘다 ([syncAfter]가 false면 끝은 부르는 쪽이): 줄마다 맞추면 1만 개에서 수십 분
  /// - 사진 링크는 새 자리 기준으로 다시 쓰고(5.5), 머리말에 번호·제목이 없으면 적는다(파일 이름이 바뀌어도 그대로이게)
  /// - 옛 경로를 가리키던 예전 되돌리기 묶음은 "경로 바뀜"으로 표시한다 (8.3) — 되돌리면 옛 자리에 같은 노트가 하나 더 생긴다.
  ///   파일마다 옮기기 전에 단다: 중간에 끊겨도(Ctrl-C·앱 종료·예외) 옮긴 노트의 옛 묶음이 표시 없이 남지 않게 (11/13 검토)
  /// - 잠금은 부를 때마다(앱은 200개 덩어리마다) 쥔다: 그사이 편집 창 저장·`brain write`는 잠금을 기다렸다가 새 자리를 고친다
  /// - 자동 목차만 남은 옛 주제 폴더는 치운다
  MoveResult moveMany(
    List<FolderMove> moves, {
    String? batch,
    void Function(int done, int total)? onProgress,
    bool syncAfter = true,
  }) => withVaultLock(vault, () {
    final batchId = batch ?? newBatchId();
    index.sync();
    final moved = <MovedNote>[];
    final errors = <MoveError>[];
    final zoneTopics = <String, List<String>>{};
    List<String> topicsOf(String zone) => zoneTopics.putIfAbsent(zone, () => [...index.zoneTopics(zone)]);
    final done = <String>{};
    final marker = MovedPathMarker(vault, batchId);
    for (final (i, move) in moves.indexed) {
      try {
        if (!done.add(move.id)) throw NoteStoreException('${move.id} 노트가 목록에 두 번 있습니다.');
        final result = _moveOne(move, batchId, topicsOf, marker);
        if (result != null) moved.add(result);
      } on NoteStoreException catch (e) {
        errors.add((id: move.id, message: e.message));
      } on FileSystemException catch (e) {
        errors.add((id: move.id, message: '${move.id} 파일을 옮기지 못했습니다: ${e.osError?.message ?? e.message} (${e.path ?? ''})'));
      }
      onProgress?.call(i + 1, moves.length);
    }
    if (moved.isNotEmpty) {
      _removeEmptyTopicDirs({for (final m in moved) p.dirname(p.join(vault.root, m.from))});
    }
    if (syncAfter) _afterChange();
    return MoveResult(batch: batchId, moved: moved, errors: errors);
  });

  MovedNote? _moveOne(FolderMove move, String batch, List<String> Function(String zone) topicsOf, MovedPathMarker marker) {
    final doc = index.byId(move.id);
    if (doc == null) throw NoteStoreException('${move.id} 노트가 없습니다.');
    if (doc.kind != 'note') throw NoteStoreException('${move.id}는 노트(wiki/)가 아니라 옮기지 않습니다.');
    final topic = move.topic.trim();
    final target = topic.contains('/') || isZoned ? resolveTopicPath(topic, topicsOf) : topicDirName(topic);
    final from = fileOf(doc);
    final content = from.readAsStringSync();
    final note = Note.parse(content, fallbackId: doc.id, fallbackTitle: doc.title);
    if (note.isFrontmatterBroken) {
      throw NoteStoreException('${move.id} 노트의 머리말(frontmatter)을 읽지 못해 옮기지 않습니다 (${doc.path}). 편집기로 고친 뒤 다시 하세요.');
    }
    final dir = p.join(vault.wikiDir, target);
    // 같은 주제로 옮기면(사이드바에서 제자리에 놓음) 이름을 줄 때만 바꾼다
    if (move.name == null && p.equals(dir, from.parent.path)) return null;
    final name = (move.name?.trim().isNotEmpty ?? false)
        ? move.name!.trim()
        : (isZoned || target.contains('/') ? shortNoteName(note.title) : p.basenameWithoutExtension(from.path));
    final to = uniqueNotePath(dir, name, self: from.path);
    if (to == from.path) return null;
    // 번호·제목을 파일 이름에서 얻던 노트는 머리말에 적어 둔다: 옮기면 경로 기반 번호(f_)·파일 이름 제목이 바뀐다.
    // 색인 번호가 머리말 번호와 다른 노트도 적는다 (11/13 검토): 머리말 `id:`가 비었거나, 다른 노트와 번호가 겹쳐(복사한 파일)
    // 색인이 f_ 번호를 준 노트는 예전에 `id:` 줄만 보고 그대로 옮겨, 새 경로로 f_ 번호가 바뀌었다.
    final declared = Note.parse(content, fallbackId: '', fallbackTitle: '');
    final hasIdentity = declared.id == doc.id && declared.title.isNotEmpty;
    var text = hasIdentity ? content : note.copyWith(id: doc.id).toMarkdown();
    text = rebaseAssetLinks(vault, text, from.path, to);
    // 순서: "경로 바뀜" 표시 → 바꾸기 전 남김 → 옮긴 기록 → 옮기기. 어디서 끊겨도 되돌리기가 노트를 둘로 만들지 않는다.
    marker.mark(doc.path);
    recordBeforeChange(vault, from.path, batch: batch);
    recordBeforeChange(vault, to, batch: batch);
    recordMove(vault, batch, from.path, to);
    Directory(p.dirname(to)).createSync(recursive: true);
    if (text == content) {
      from.renameSync(to);
    } else {
      writeFileAtomic(to, text);
      from.deleteSync();
    }
    final rel = p.relative(to, from: vault.root);
    if (target.contains('/')) {
      final [zone, leaf] = target.split('/');
      if (!topicsOf(zone).contains(leaf)) topicsOf(zone).add(leaf);
    }
    appendChangeLog(vault, 'move', '${doc.id} ${doc.path} → $rel', batch: batch);
    return (id: doc.id, from: doc.path, to: rel);
  }

  /// 옮긴 뒤 자동 목차(`index.md`, 첫 줄 "(자동 생성)")만 남은 옛 주제 폴더를 지운다. 사용자가 둔 파일이 있으면 그대로.
  void _removeEmptyTopicDirs(Set<String> dirs) {
    for (final dir in dirs) {
      if (p.equals(dir, vault.wikiDir) || !p.isWithin(vault.wikiDir, dir)) continue;
      final folder = Directory(dir);
      if (!folder.existsSync()) continue;
      final entries = folder.listSync();
      final rest = [for (final e in entries) if (p.basename(e.path) != 'index.md' && p.basename(e.path) != '.DS_Store') e];
      if (rest.isNotEmpty) continue;
      final auto = File(p.join(dir, 'index.md'));
      if (auto.existsSync() && !auto.readAsStringSync().split('\n').first.contains('(자동 생성)')) continue;
      try {
        folder.deleteSync(recursive: true);
      } on FileSystemException {
        // 못 지워도 옮기기는 끝났다: 빈 폴더가 사이드바에 남을 뿐이다
      }
    }
  }

  /// 추천 정리: 연결(직접·추천)의 다수가 다른 주제에 있는 노트를 그 주제로 옮기자고 제안한다.
  /// 노트를 고치지 않고 제안만 돌려준다. (노트 id, 지금 주제, 제안 주제, 근거 연결 수)
  List<(String, String, String, int)> suggestMoves({int minLinks = 2}) {
    index.sync();
    // 구역이 달라도 주제 이름이 같을 수 있어 주제 경로로 센다. 구역을 쓰면 구역 밖(예전) 주제로는 옮기자고 하지 않는다.
    final topicOf = {for (final d in index.notes()) d.id: d.topicPath};
    bool isTarget(String topic) => !isZoned || topic.contains('/');
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
      if (best.key != current && best.value >= minLinks && best.value > here && isTarget(best.key)) {
        out.add((e.key, current, best.key, best.value));
      }
    }
    out.sort((a, b) => b.$4.compareTo(a.$4));
    return out;
  }

  /// 노트를 지운다. 실제로는 `_meta/trash/<묶음>/`으로 옮겨서 `brain undo`로 되살릴 수 있다.
  String delete(String id, {String? batch}) => withVaultLock(vault, () {
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
  });

  /// 정리 대기 → 정리됨 같은 상태 바꾸기.
  void setStatus(String id, NoteStatus status, {String? batch}) => withVaultLock(vault, () {
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
  });

  /// 노트를 "합쳐짐"으로 남기고 [into]를 가리키게 한다 (`redirect:`, 설계서 5.8 중복 후보).
  /// 지우지 않는다: 되돌릴 수 있고, 옛 링크·대화 속 id가 어디로 갔는지 따라갈 수 있다 (설계서_프롬프트이후 4.2·4.4).
  void markMerged(String id, {required String into, String? batch}) => withVaultLock(vault, () {
    if (id == into) throw NoteStoreException('$id 노트를 자기 자신에 합칠 수 없습니다.');
    final (doc, note, _) = _readForChange(id);
    if (index.byId(into) == null) throw NoteStoreException('$into 노트가 없습니다.');
    recordBeforeChange(vault, fileOf(doc).path, batch: batch);
    writeFileAtomic(
      fileOf(doc).path,
      note
          .copyWith(status: NoteStatus.merged, updated: DateTime.now(), extra: {...note.extra, 'redirect': into})
          .toMarkdown(),
    );
    appendChangeLog(vault, 'merge', '$id → $into ${doc.path}', batch: batch);
    _afterChange();
  });

  /// 정리 대기 초안마다 비슷한 정리된 노트 최대 [perDraft]개 (설계서_프롬프트이후 4.2). 초안 id → 점수 높은 순.
  /// 초안이 아주 많아도 보드가 늦게 뜨지 않게 앞 [maxDrafts]개만 본다 (보드도 최근 순으로 보인다).
  Map<String, List<SimilarNote>> similarForDrafts({int perDraft = 2, int maxDrafts = 200}) {
    final out = <String, List<SimilarNote>>{};
    for (final doc in index.notes().where((d) => d.isDraft).take(maxDrafts)) {
      final String text;
      try {
        text = fileOf(doc).readAsStringSync();
      } on FileSystemException {
        continue; // 그사이 지워졌거나 읽을 수 없는 초안은 건너뛴다
      }
      final note = Note.parse(text, fallbackId: doc.id, fallbackTitle: doc.title);
      final similar = index.similarNotes(note, excludeId: doc.id, limit: perDraft);
      if (similar.isNotEmpty) out[doc.id] = similar;
    }
    return out;
  }

  /// 정리 대기 카드의 [합치기] (설계서_프롬프트이후 4.2): 초안 본문을 정리된 노트 끝에 붙이고, 초안은 "합쳐짐"으로 남긴다.
  /// 두 파일을 한 묶음으로 바꿔 한 번에 되돌린다. 반환: 묶음 id.
  ///
  /// 둘 다 되거나 둘 다 안 된다 (11/13 검토: 붙인 뒤 초안 표시가 실패하면 붙인 것만 남아 다시 누르면 두 번 붙었다).
  /// - 지식 폴더 잠금 안에서 한다: 앱과 `brain`이 같은 초안을 동시에 합치지 않게
  /// - 초안 표시가 실패하면 대상 노트를 붙이기 전 내용으로 되돌리고 다시 던진다
  /// - 대상에 이 초안의 "합친 초안" 머리가 이미 있으면(예전 판에서 끊긴 경우) 또 붙이지 않고 초안 표시만 한다
  String mergeDraftInto(String draftId, String targetId, {String? batch}) => withVaultLock(vault, () {
    final batchId = batch ?? newBatchId();
    final (_, draft, _) = _readForChange(draftId);
    if (!draft.isDraft) throw NoteStoreException('$draftId 노트는 초안이 아니라 합치지 않습니다.');
    final (targetDoc, target, hash) = _readForChange(targetId);
    if (targetDoc.status != NoteStatus.active) {
      throw NoteStoreException('$targetId 노트는 정리된 노트가 아니라 합치지 않습니다 (${targetDoc.status.label}).');
    }
    final targetFile = fileOf(targetDoc);
    final original = targetFile.readAsStringSync();
    final isAppended = RegExp(
      '^## 합친 초안: .* \\(\\d{4}-\\d{2}-\\d{2}, ${RegExp.escape(draftId)}\\)\$',
      multiLine: true,
    ).hasMatch(target.body);
    if (!isAppended) {
      final date = formatTime(DateTime.now()).substring(0, 10);
      update(
        targetId,
        expectHash: hash,
        title: target.title,
        summary: target.summary,
        body: '${target.body.trimRight()}\n\n## 합친 초안: ${draft.title} ($date, $draftId)\n\n${draft.body.trim()}\n',
        tags: target.tags,
        aliases: target.aliases,
        batch: batchId,
      );
    }
    try {
      markMerged(draftId, into: targetId, batch: batchId);
    } on Object {
      if (!isAppended) {
        // 붙인 것을 되돌린다. 기록에도 남겨 묶음의 "바꾼 뒤" 해시가 되돌린 내용과 맞게 한다.
        writeFileAtomic(targetFile.path, original);
        appendChangeLog(vault, 'update', '$targetId 합치기 실패로 되돌림 ${targetDoc.path}', batch: batchId);
        _afterChange();
      }
      rethrow;
    }
    return batchId;
  });

  /// 색인을 맞추고 목차·온보딩 요약을 다시 만든다.
  void _afterChange() {
    index.sync();
    VaultSummary(vault, index).writeAll();
  }
}

bool _sameList(List<String> a, List<String> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);
