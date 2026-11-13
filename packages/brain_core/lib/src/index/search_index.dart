import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../graph/layout_health.dart';
import '../lessons/lesson.dart';
import '../note/note.dart';
import '../note/note_assets.dart';
import '../note/wiki_links.dart';
import '../note/zones.dart';
import '../vault/vault.dart';
import '../text/nfc.dart';
import 'bigram.dart';

/// 색인에 올라간 문서 한 개 (설계서 4.2 `docs` 표).
class IndexedDoc {
  const IndexedDoc({
    required this.id,
    required this.path,
    required this.kind,
    required this.title,
    required this.summary,
    required this.tags,
    required this.status,
    required this.mtime,
    required this.hash,
    this.statusText = 'active',
  });

  final String id;

  /// 지식 폴더 기준 상대 경로 (`wiki/결제/결제 웹훅.md`).
  final String path;
  final String kind;
  final String title;
  final String summary;
  final String tags;
  final NoteStatus status;

  /// 파일에 적힌 상태 그대로 (실수 노트는 pending·active·archived).
  final String statusText;
  final DateTime mtime;
  final String hash;

  bool get isDraft => status == NoteStatus.draft;

  bool get isMerged => status == NoteStatus.merged;

  /// 구역 (설계서_프롬프트이후 5.1): `wiki/개발 지식/Flutter/a.md` → `개발 지식`. 구역 밖(예전 방식) 노트는 null.
  String? get zone {
    final parts = path.split('/');
    return parts.length >= 4 && noteZones.contains(parts[1]) ? parts[1] : null;
  }

  /// 주제 이름: `wiki/개발 지식/Flutter/a.md` → `Flutter`, 예전 `wiki/결제/a.md` → `결제`. wiki 바로 아래 파일이면 `미분류`.
  /// 구역이 달라도 이름이 같을 수 있으니 묶을 때는 [topicPath]를 쓴다.
  String get topic {
    final parts = path.split('/');
    if (zone != null) return parts[2];
    return parts.length >= 3 ? parts[1] : '미분류';
  }

  /// 주제 폴더의 wiki 기준 경로: `개발 지식/Flutter` 또는 예전 `결제`. 묶기·범위 찾기·옮기기 대상에 쓴다.
  String get topicPath => zone == null ? topic : '$zone/$topic';

  /// `wiki/결제` 처럼 파일이 든 폴더.
  String get folder => p.dirname(path);

  static IndexedDoc fromRow(Row row) => IndexedDoc(
    id: row['id'] as String,
    path: row['path'] as String,
    kind: row['kind'] as String,
    title: row['title'] as String,
    summary: (row['summary'] as String?) ?? '',
    tags: (row['tags'] as String?) ?? '',
    status: NoteStatus.parse(row['status']),
    statusText: (row['status'] as String?) ?? 'active',
    mtime: DateTime.fromMillisecondsSinceEpoch(row['mtime'] as int),
    hash: row['hash'] as String,
  );
}

/// 비슷한 정리된 노트 한 개 ([SearchIndex.similarNotes]). [shared]는 핵심 단어 [terms]개 중 겹친 수.
class SimilarNote {
  const SimilarNote({required this.doc, required this.shared, required this.terms});

  final IndexedDoc doc;
  final int shared;
  final int terms;
}

/// 노트 사이 연결 한 개 (설계서 4.2 `links`). manual = `[[제목]]`, suggested = 추천.
class NoteLink {
  const NoteLink({
    required this.fromId,
    required this.toId,
    required this.kind,
    this.score = 1,
  });

  final String fromId;
  final String toId;
  final String kind;
  final double score;

  bool get isSuggested => kind == 'suggested';
}

/// 대상 노트가 없는 `[[제목]]`.
class DeadLink {
  const DeadLink({required this.fromId, required this.target});

  final String fromId;
  final String target;
}

class SyncResult {
  const SyncResult({
    required this.added,
    required this.updated,
    required this.removed,
  });

  final int added;
  final int updated;
  final int removed;

  int get changed => added + updated + removed;

  @override
  String toString() => '추가 $added · 갱신 $updated · 삭제 $removed';
}

/// 파일 내용의 sha1 앞 12자리. `brain write --expect-hash`에 쓴다.
String contentHash(String content) =>
    sha1.convert(utf8.encode(content)).toString().substring(0, 12);

/// SQLite FTS5 검색 색인. 원본이 아니라서 언제든 다시 만들 수 있다.
class SearchIndex {
  SearchIndex._(this.vault, this._db);

  /// [rebuildIfOld]가 false면 색인 버전이 낮아도 여기서 다시 만들지 않는다 ([isRebuildPending]).
  /// 앱의 화면 스레드 쪽이 이렇게 연다: 노트 1만 개를 다시 색인하면 10초 넘게 멈춘다 (11/11 K-32).
  /// 다시 만들기는 앱 시작 동기화(백그라운드)가 기본값으로 열면서 한다.
  ///
  /// [busyTimeout]: 다른 연결이 쓰는 중일 때 기다리는 시간. 기본 5초. 앱의 저장처럼 사용자가 기다리는 쓰기는
  /// 길게 준다 — 처음 색인(노트 1만 개 12~20초)과 겹치면 5초 뒤 "database is locked"로 실패했다 (11/12).
  factory SearchIndex.open(
    Vault vault, {
    String? path,
    bool rebuildIfOld = true,
    Duration busyTimeout = const Duration(seconds: 5),
  }) {
    final dbPath = path ?? vault.indexPath;
    Directory(p.dirname(dbPath)).createSync(recursive: true);
    Database db;
    try {
      db = _openDb(dbPath, busyTimeout);
    } on SqliteException catch (e) {
      // 색인 파일이 깨졌으면(11 CORRUPT, 26 NOTADB) 지우고 새로 만든다. 색인은 원본(md)에서 언제든 다시 만들 수 있다
      // (설계서 5.7). 예전에는 앱이 예외 화면에서 멈췄다 (11/11 K-32). 그래프 위치·세션 요약 캐시는 다시 계산된다.
      if (e.resultCode != 11 && e.resultCode != 26) rethrow;
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('$dbPath$suffix');
        if (file.existsSync()) file.deleteSync();
      }
      db = _openDb(dbPath, busyTimeout);
    }
    final index = SearchIndex._(vault, db);
    final version = db.select('pragma user_version').first.values.first as int;
    if (version < schemaVersion) {
      if (rebuildIfOld) {
        index._rebuildIfStillOld();
      } else {
        index._isRebuildPending = true;
      }
    }
    return index;
  }

  static Database _openDb(String dbPath, Duration busyTimeout) {
    final db = sqlite3.open(dbPath);
    try {
      _createSchema(db, busyTimeout);
      return db;
    } on Object {
      db.close();
      rethrow;
    }
  }

  static void _createSchema(Database db, Duration busyTimeout) {
    // 기다리기 설정을 먼저 한다: journal_mode를 바꾸는 순간에도 다른 프로세스가 WAL을 복구하고 있으면
    // 기다리지 않고 BUSY_RECOVERY(261)로 실패했다 (11/12 동시 brain add 8개 시험).
    db.execute('pragma busy_timeout = ${busyTimeout.inMilliseconds}');
    db.execute('pragma journal_mode = wal');
    db.execute('''
      create table if not exists docs (
        rowid integer primary key,
        id text not null unique,
        path text not null unique,
        kind text not null,
        title text not null,
        summary text,
        tags text,
        status text not null default 'active',
        mtime integer not null,
        size integer not null,
        hash text not null
      );
      create virtual table if not exists docs_fts using fts5(
        title_grams, body_grams,
        tokenize = 'unicode61', content = '', contentless_delete = 1
      );
      create table if not exists session_cache (
        path text primary key,
        mtime integer not null,
        size integer not null,
        summary text not null
      );
      create table if not exists doc_names (
        doc_rowid integer not null,
        name text not null
      );
      create index if not exists doc_names_name on doc_names(name);
      create table if not exists link_targets (
        from_rowid integer not null,
        target text not null,
        label text not null
      );
      create table if not exists graph_pos (
        id text primary key,
        x real not null,
        y real not null
      );
      create table if not exists index_meta (
        key text primary key,
        value integer not null
      );
      create table if not exists suggested_links (
        from_rowid integer not null,
        to_rowid integer not null,
        score real not null,
        primary key (from_rowid, to_rowid)
      );
    ''');
    // 스키마를 읽는 것까지 해 봐야 깨진 파일을 알 수 있다
    db.select('pragma user_version');
  }

  /// 색인 표 구조가 바뀌면 올린다. 열 때 낮으면 처음부터 다시 색인한다.
  static const schemaVersion = 6;

  /// 추천 연결 기준: 핵심 단어 5개 중 이만큼 겹치는 노트만 잇는다 (3주차 bench로 조정).
  /// 점수 = 겹친 수 / 핵심 단어 수. 연결 이유를 사람이 읽을 수 있게 하려고 bm25 비율 대신 쓴다.
  static const suggestMinShared = 2;

  /// 노트당 추천 연결 최대 개수 (설계서 5.5).
  static const suggestLimit = 5;

  /// 정리 대기 카드에 비슷한 노트를 보이는 문턱: 핵심 단어 5개 중 겹친 수 (설계서_프롬프트이후 4.2, 측정 M5).
  /// 11/13 시험 묶음(similar_notes_test): 2는 중복 아닌 초안 20개 중 3개에 떴고, 3은 중복 10/10 표시·오표시 1/20,
  /// 4는 중복 9/10·오표시 0/20. 놓치는 중복이 더 아까워 3.
  static const similarShowMin = 3;

  /// `brain add`가 저장을 한 번 멈추는 "강하게 맞음" 문턱 (설계서_프롬프트이후 4.4).
  /// 같은 묶음에서 3은 바꾼 결정 9/10 멈춤·같은 주제 다른 지식 0/10, 4는 바꾼 결정 4/10뿐이었다 —
  /// 결정을 바꾼 노트는 숫자·이름이 바뀌어 핵심 단어가 덜 겹친다.
  static const similarStrongMin = 3;

  final Vault vault;
  final Database _db;

  /// 마지막 [sync]에서 읽지 못해 건너뛴 파일 (지식 폴더 기준 경로와 이유).
  /// UTF-8이 아닌 .md(옛 CP949 회의록 등)나 권한 없는 파일 하나 때문에 색인 전체가 멈추던 것을 막는다 (11/11 K-20).
  /// `brain lint`·`brain doctor`·앱이 이 목록을 보여 준다.
  List<(String, String)> unreadable = const [];

  Database get db => _db;

  /// 자주 쓰는 SQL은 한 번만 준비해 다시 쓴다. `execute(sql, 인자)`는 부를 때마다 준비·해제해
  /// 처음 색인(1만 개, 문장 약 7만 번)에서 시간이 컸다 (11/11 검토 O-9).
  final _prepared = <String, PreparedStatement>{};

  PreparedStatement _stmt(String sql) => _prepared[sql] ??= _db.prepare(sql);

  void close() {
    for (final statement in _prepared.values) {
      statement.close();
    }
    _prepared.clear();
    _db.close();
  }

  /// 빠른 동기화: 폴더 수정 시각만 보고 바뀐 게 있을 때만 [sync]한다 (`brain find`·훅용).
  ///
  /// 노트 1만 개에서 [sync]는 파일 1만 개의 수정 시각을 읽어 140ms쯤 걸린다 (설계서 5.8 `find` 50ms 목표).
  /// 파일을 더하거나 지우거나 이름을 바꾸거나 원자적으로 쓰면(임시 파일 → 이름 바꾸기, `brain add`·앱) 그
  /// 폴더 수정 시각이 바뀌므로 폴더 몇십 개만 보면 된다. 제자리에서 고친 파일은 폴더 시각이 안 바뀌므로
  /// [fullEvery]가 지나면 한 번은 전체를 본다 (앱이 켜져 있으면 폴더 감시로 바로 반영된다).
  SyncResult syncIfStale({Duration fullEvery = const Duration(minutes: 10)}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    // 훅 한 번에 실수 노트 조회와 관련 노트 찾기가 각각 부른다. 방금 확인했으면 다시 훑지 않는다
    // (노트 1만 개에서 한 번에 약 10ms, 11/11 검토 O-3). 바꾸는 쪽은 늘 sync()를 직접 부른다.
    // 부른 쪽이 더 자주 전체를 보라고 하면(fullEvery가 2초보다 짧으면) 따른다.
    const window = 2000;
    final checked = _staleCheckedAt;
    if (fullEvery.inMilliseconds > window && checked != null && now - checked >= 0 && now - checked < window) {
      return const SyncResult(added: 0, updated: 0, removed: 0);
    }
    final result = _syncIfChanged(now, fullEvery);
    _staleCheckedAt = now; // sync()가 지운 뒤에 적는다
    return result;
  }

  SyncResult _syncIfChanged(int now, Duration fullEvery) {
    if (isRebuildPending) return const SyncResult(added: 0, updated: 0, removed: 0);
    _checkVaultExists();
    final last = _meta('synced_at');
    if (last == null || now - last > fullEvery.inMilliseconds) return sync();
    final dirs = {
      vault.wikiDir,
      // 구역 폴더: 다른 프로세스가 구역 안에 새 주제 폴더를 만들면 바뀌는 것은 구역 폴더의 시각뿐이다 (설계서_프롬프트이후 5.1)
      for (final zone in noteZones) p.join(vault.wikiDir, zone),
      p.join(vault.root, 'raw'),
      vault.lessonsDir,
      // 폴더 이름은 SQL에서 뽑는다 (경로 1만 개를 Dart로 옮겨 자르는 것보다 빠름): 마지막 '/'까지 남기기
      for (final row in _db.select(
        "select distinct rtrim(path, replace(path, '/', '')) as dir from docs",
      ))
        p.join(vault.root, row['dir'] as String),
    };
    for (final dir in dirs) {
      final stat = FileStat.statSync(dir);
      if (stat.type == FileSystemEntityType.notFound) continue;
      // 1초 여유: 파일 시스템 시각 단위와 동기화 도중 바뀐 것까지 잡는다.
      if (stat.modified.millisecondsSinceEpoch >= last - 1000) return sync();
    }
    return const SyncResult(added: 0, updated: 0, removed: 0);
  }

  int? _meta(String key) {
    final rows = _db.select('select value from index_meta where key = ?', [
      key,
    ]);
    return rows.isEmpty ? null : rows.first['value'] as int;
  }

  /// 바뀐 md 파일만 다시 색인한다 (수정 시각·크기 → 다르면 해시).
  /// 지식 폴더가 없는데 색인에 문서가 있으면 동기화하지 않는다 (지우면 모든 노트가 사라진 것처럼 보인다, K-32).
  /// 색인이 비어 있으면(처음 쓰는 폴더) 지킬 것이 없으므로 그대로 둔다 — `brain add`가 폴더를 만든다.
  void _checkVaultExists() {
    if (Directory(vault.root).existsSync()) return;
    if (_db.select('select 1 from docs limit 1').isNotEmpty) throw VaultMissingException(vault.root);
  }

  bool _isRebuildPending = false;

  /// 색인 버전이 낮은데 이 연결은 다시 만들지 않기로 열었다 ([SearchIndex.open]의 `rebuildIfOld: false`).
  /// 그동안 [sync]·[syncIfStale]은 아무것도 하지 않고, 읽기는 옛 색인으로 한다. 쓰기(노트 저장)는 이렇게 연
  /// 연결로 하지 않는다: 저장 뒤 확인이 색인에 기대므로 기본값으로 열어 다시 만들기를 기다리게 한다.
  /// 다른 연결이 다시 만들면 다음 확인 때 풀린다.
  bool get isRebuildPending {
    if (!_isRebuildPending) return false;
    final version = _db.select('pragma user_version').first.values.first as int;
    if (version >= schemaVersion) _isRebuildPending = false;
    return _isRebuildPending;
  }

  /// [syncIfStale]이 마지막으로 폴더를 확인한 시각 (같은 프로세스 안에서만).
  int? _staleCheckedAt;

  SyncResult sync() {
    _staleCheckedAt = null;
    if (isRebuildPending) return const SyncResult(added: 0, updated: 0, removed: 0);
    _checkVaultExists();
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final existing = {
      for (final row in _db.select(
        'select rowid, path, mtime, size, hash, kind, id, title from docs',
      ))
        row['path'] as String: row,
    };
    // 1) 지금 있는 파일을 모은다.
    final files = <(String, String, File)>[];
    final rootPrefix = '${vault.root}${p.separator}';
    for (final (dir, kind) in [
      (vault.wikiDir, 'note'),
      (p.join(vault.root, 'raw'), 'raw'),
      (vault.lessonsDir, 'lesson'),
    ]) {
      final root = Directory(dir);
      if (!root.existsSync()) continue;
      for (final entity in root.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.md')) continue;
        // 목록의 경로는 지식 폴더 경로로 시작하므로 잘라 쓴다. `p.relative`·`p.split`은 파일 1만 개에서
        // 변경 없는 동기화(약 120ms)의 1/3을 차지했다 (11/12 측정). 모양이 다르면 예전 방법으로.
        final rel = toNfc(
          entity.path.startsWith(rootPrefix)
              ? entity.path.substring(rootPrefix.length)
              : p.relative(entity.path, from: vault.root),
        );
        final parts = rel.split('/');
        if (parts.any((part) => part.startsWith('.'))) continue;
        // 자동 생성 목차·검증 기준 파일은 노트가 아니다.
        final name = parts.last;
        if (name == 'index.md') continue;
        if (name.startsWith('_')) continue;
        final docKind = kind == 'lesson' && parts.contains('tests')
            ? 'test'
            : kind;
        files.add((rel, docKind, entity));
      }
    }
    final seen = {for (final (rel, _, _) in files) rel};
    final skipped = <(String, String)>[];
    var added = 0;
    var updated = 0;
    var removed = 0;
    final changed = <(int, Note)>[];
    // [rebuild]가 연 트랜잭션 안에서 불리면 그 트랜잭션에 함께 들어간다.
    final ownsTransaction = _db.autocommit;
    // 쓰기 잠금을 먼저 잡는다: 읽다가 쓰기로 올리면 다른 프로세스와 겹칠 때 기다리지 않고 BUSY가 난다 (K-32)
    if (ownsTransaction) _db.execute('begin immediate');
    try {
      // 2) 옮기기만 한 파일(내용이 같고 번호·제목이 머리말에 있음)은 색인 줄의 경로만 바꾼다 (설계서_프롬프트이후 5.1).
      //    폴더 정리로 1만 개를 옮기면 지우고 다시 색인하는 데 약 20초 걸렸다. 줄 번호가 그대로라 연결·추천도 그대로다.
      final gone = <String, List<Row>>{}; // 내용 해시 → 없어진 경로의 줄
      for (final entry in existing.entries) {
        if (!seen.contains(entry.key)) gone.putIfAbsent(entry.value['hash'] as String, () => []).add(entry.value);
      }
      final moved = <String>{};
      final contents = <String, String>{}; // 한 번 읽은 새 파일 (3에서 다시 읽지 않게)
      if (gone.isNotEmpty) {
        for (final (rel, kind, file) in files) {
          if (existing.containsKey(rel) || (kind != 'note' && kind != 'raw')) continue;
          final String content;
          try {
            content = file.readAsStringSync();
          } on FileSystemException {
            continue; // 3에서 다시 읽고 건너뜀 목록에 넣는다
          }
          final candidates = gone[contentHash(content)];
          final note = candidates == null
              ? null
              : Note.parse(content, fallbackId: '', fallbackTitle: p.basenameWithoutExtension(rel));
          final row = candidates?.where((r) => r['kind'] == kind && r['id'] == note!.id && r['title'] == note.title).firstOrNull;
          if (row == null) {
            contents[rel] = content;
            continue;
          }
          candidates!.remove(row);
          final stat = file.statSync();
          _db.execute('update docs set path = ?, mtime = ?, size = ? where rowid = ?', [
            rel,
            stat.modified.millisecondsSinceEpoch,
            stat.size,
            row['rowid'],
          ]);
          moved.add(rel);
          updated++;
        }
      }
      // 3) 남은 없어진 파일을 먼저 지운다. 이름이 바뀐 파일(옛 경로 삭제 + 새 경로 추가)이
      //    잠깐이라도 같은 id를 둘 갖지 않게 하려는 순서다.
      for (final rows in gone.values) {
        for (final row in rows) {
          _deleteRow(row['rowid'] as int);
          removed++;
        }
      }
      // 4) 바뀐 파일만 다시 색인한다 (수정 시각·크기 → 다르면 해시).
      for (final (rel, kind, file) in files) {
        if (moved.contains(rel)) continue;
        final stat = file.statSync();
        final mtime = stat.modified.millisecondsSinceEpoch;
        final old = existing[rel];
        if (old != null && old['mtime'] == mtime && old['size'] == stat.size) {
          continue;
        }
        final String content;
        try {
          content = contents[rel] ?? file.readAsStringSync();
        } on FileSystemException catch (e) {
          // 읽지 못한 파일은 건너뛰고(이전 색인 줄은 그대로) 목록으로 알린다.
          skipped.add((rel, e.osError?.message ?? e.message));
          continue;
        }
        final hash = contentHash(content);
        if (old != null && old['hash'] == hash) {
          _db.execute('update docs set mtime = ?, size = ? where path = ?', [
            mtime,
            stat.size,
            rel,
          ]);
          continue;
        }
        changed.add(
          _upsert(
            rel,
            kind,
            content,
            hash,
            mtime,
            stat.size,
            old?['rowid'] as int?,
          ),
        );
        old == null ? added++ : updated++;
      }
      // 노트가 많이 바뀌면(처음 색인·대량 가져오기) 조각별 문서 수를 한 번에 읽어 둔다.
      // 노트마다 조각 수백 개를 하나씩 물으면 1만 개에 200초가 넘게 걸렸다 (11/07 측정).
      if (changed.length >= 50) _loadVocab();
      try {
        for (final (rowid, note) in changed) {
          _suggestFor(rowid, note);
        }
      } finally {
        _vocab = null;
      }
      _db.execute(
        'insert or replace into index_meta(key, value) values (?, ?)',
        ['synced_at', startedAt],
      );
      if (ownsTransaction) _db.execute('commit');
      unreadable = skipped;
      return SyncResult(added: added, updated: updated, removed: removed);
    } catch (_) {
      if (ownsTransaction) _db.execute('rollback');
      rethrow;
    }
  }

  /// 색인을 지우고 처음부터 다시 만든다.
  ///
  /// 지우기부터 다시 채우기·버전 올리기까지 한 트랜잭션이다 (11/11 K-32). 예전에는 지우기가 먼저 확정돼
  /// - 다시 만드는 동안 다른 프로세스(`brain find`·앱)가 빈 색인을 보고 "노트 없음"이라고 했고,
  /// - 중간에 실패하면 빈 색인이 남았고,
  /// - 지식 폴더가 없으면 지운 뒤라 폴더 확인을 지나쳐 빈 색인으로 끝났다.
  SyncResult rebuild() {
    _checkVaultExists();
    _db.execute('begin immediate');
    try {
      final result = _rebuildInTransaction();
      _db.execute('commit');
      _isRebuildPending = false;
      return result;
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    }
  }

  /// 열 때 버전이 낮으면 다시 만든다. 잠금을 잡은 뒤 버전을 다시 본다: 다른 프로세스·isolate가 먼저
  /// 끝냈으면 또 하지 않는다 (앱 시작 때 백그라운드 작업 여럿이 한꺼번에 연다).
  void _rebuildIfStillOld() {
    _checkVaultExists();
    _db.execute('begin immediate');
    try {
      final version = _db.select('pragma user_version').first.values.first as int;
      if (version < schemaVersion) _rebuildInTransaction();
      _db.execute('commit');
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    }
  }

  SyncResult _rebuildInTransaction() {
    _db.execute('delete from docs_fts');
    _db.execute('delete from docs');
    _db.execute('delete from doc_names');
    _db.execute('delete from link_targets');
    _db.execute('delete from suggested_links');
    _db.execute('delete from graph_pos'); // 배치 규칙이 바뀌었을 수 있어 다시 배치한다
    _db.execute("delete from index_meta where key like 'layout_%'");
    final result = sync();
    _db.execute("insert into docs_fts(docs_fts) values('optimize')");
    _db.execute('pragma user_version = $schemaVersion');
    return result;
  }

  void _deleteRow(int rowid) {
    _db.execute('delete from docs_fts where rowid = ?', [rowid]);
    _db.execute('delete from docs where rowid = ?', [rowid]);
    _db.execute('delete from doc_names where doc_rowid = ?', [rowid]);
    _db.execute('delete from link_targets where from_rowid = ?', [rowid]);
    _db.execute(
      'delete from suggested_links where from_rowid = ? or to_rowid = ?',
      [rowid, rowid],
    );
  }

  (int, Note) _upsert(
    String rel,
    String kind,
    String content,
    String hash,
    int mtime,
    int size,
    int? rowid,
  ) {
    final fallbackId = kind == 'raw' ? 'r_$hash' : 'f_${contentHash(rel)}';
    final note = switch (kind) {
      'lesson' => _lessonAsNote(Lesson.parse(content, fallbackId: fallbackId)),
      'test' => _testAsNote(LessonTest.parse(content, fallbackId: fallbackId)),
      _ => Note.parse(
        content,
        fallbackId: fallbackId,
        fallbackTitle: p.basenameWithoutExtension(rel),
      ),
    };
    final statusText = kind == 'lesson'
        ? Lesson.parse(content, fallbackId: fallbackId).status.value
        : note.status.value;
    if (rowid != null) _deleteRow(rowid);
    // 같은 id가 다른 파일에 이미 있으면(복사한 파일) 경로 기반 id로 바꾼다.
    // 그 파일이 이미 없으면 복사가 아니라 옮긴 것이다: 폴더 목록을 읽는 사이 다른 프로세스가 옮기면(폴더 정리 1만 개,
    // 설계서_프롬프트이후 5.1) 옛 경로와 새 경로가 함께 목록에 잡힌다. 그때 새 경로가 f_ 번호를 받으면 다음 동기화에서도
    // 그대로 남아 노트 번호가 바뀌었다 → 옛 줄을 지우고 번호를 이어받는다.
    var id = note.id;
    final holders = _db.select('select rowid, path from docs where id = ?', [id]);
    for (final holder in holders) {
      if (File(p.join(vault.root, holder['path'] as String)).existsSync()) {
        id = 'f_${contentHash(rel)}';
        break;
      }
      _deleteRow(holder['rowid'] as int);
    }
    _stmt(
      'insert into docs(id, path, kind, title, summary, tags, status, mtime, size, hash) '
      'values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    ).execute([
      id,
      rel,
      kind,
      note.title,
      note.summary,
      note.tags.join(', '),
      statusText,
      mtime,
      size,
      hash,
    ]);
    final newRowid = _db.lastInsertRowId;
    final titleText = [note.title, ...note.aliases, ...note.tags].join(' ');
    _stmt(
      'insert into docs_fts(rowid, title_grams, body_grams) values (?, ?, ?)',
    ).execute([
      newRowid,
      toBigrams(titleText),
      // 사진 링크는 설명 글만 색인한다: 경로의 assets·png로 노트가 찾히지 않게 (설계서_프롬프트이후 5.5)
      toBigrams('${note.summary}\n${note.body.replaceAllMapped(assetImageLink, (m) => m.group(1)!)}'),
    ]);
    if (kind == 'note') {
      for (final name in {linkKey(note.title), ...note.aliases.map(linkKey)}) {
        if (name.isEmpty) continue;
        _stmt('insert into doc_names(doc_rowid, name) values (?, ?)')
            .execute([newRowid, name]);
      }
      for (final target in parseWikiLinks(note.body)) {
        _stmt(
          'insert into link_targets(from_rowid, target, label) values (?, ?, ?)',
        ).execute([newRowid, linkKey(target), target]);
      }
    }
    return (newRowid, note);
  }

  /// 실수 노트는 trigger → action을 제목으로, reason을 요약으로 색인한다.
  static Note _lessonAsNote(Lesson lesson) => Note(
    id: lesson.id,
    title: lesson.line,
    summary: lesson.reason,
    body: '${lesson.diff}\n${lesson.body}',
  );

  /// 회귀 시험은 질문을 제목으로, 통과 조건을 요약으로 색인한다.
  static Note _testAsNote(LessonTest test) => Note(
    id: test.id,
    title: test.question,
    summary: test.expect,
    body: '${test.bad}\n${test.lesson}',
  );

  /// 제목·요약·본문의 핵심 조각으로 비슷한 노트를 찾아 추천 연결로 남긴다 (설계서 5.5).
  ///
  /// 핵심 조각: 이 노트에 자주 나오고 전체 노트에는 드문 2글자 조각·영어 단어 상위 5개.
  /// 띄어쓰기를 건너 생긴 경계 조각은 원문에 그대로 없으므로 뺀다.
  void _suggestFor(int rowid, Note note) {
    _stmt('delete from suggested_links where from_rowid = ?').execute([rowid]);
    final rows = _stmt(
      "select kind from docs where rowid = ? and kind = 'note'",
    ).select([rowid]);
    if (rows.isEmpty) return;
    // 노트는 방금 색인할 때 읽고 푼 것을 그대로 쓴다 (예전에는 파일을 다시 읽고 다시 풀었다, 11/11 검토 O-9).
    final terms = keyTerms(note);
    if (terms.length < suggestMinShared) return;
    // 핵심 단어가 몇 개 겹치는지 센다. 핵심 단어는 드문 조각이라 결과가 많지 않다.
    final shared = <int, int>{};
    for (final term in terms) {
      for (final row in _stmt(
        'select f.rowid as rowid from docs_fts f join docs d on d.rowid = f.rowid '
        "where docs_fts match ? and d.kind = 'note' limit 500",
      ).select(['"$term"'])) {
        final other = row['rowid'] as int;
        if (other != rowid) {
          shared.update(other, (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }
    final candidates =
        shared.entries.where((e) => e.value >= suggestMinShared).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in candidates.take(suggestLimit)) {
      _stmt(
        'insert or replace into suggested_links(from_rowid, to_rowid, score) values (?, ?, ?)',
      ).execute([rowid, entry.key, entry.value / terms.length]);
    }
  }

  /// [note]와 비슷한 **정리된** 노트 (설계서_프롬프트이후 4.2·4.4). 점수는 추천 연결과 같다:
  /// [note]의 핵심 단어 5개 중 상대 노트에 나오는 수. AI 호출이 없다.
  ///
  /// 초안·합쳐짐은 뺀다: 정리 대기 카드에 "이미 있는 지식"으로, `brain add`에 "고칠 옛 노트"로 보여 주는 것이라
  /// 확인 전 초안을 근거로 쓰면 안 된다(4.1). [topic](주제 경로 [IndexedDoc.topicPath])을 주면 그 주제 폴더 안에서만 찾는다.
  /// 저장 전 노트([note]가 색인에 없음)에도 쓴다: 핵심 단어 수만큼 FTS 질의라 1만 개에서도 빠르다.
  List<SimilarNote> similarNotes(
    Note note, {
    String? excludeId,
    String? topic,
    int minShared = similarShowMin,
    int limit = 3,
  }) {
    final terms = keyTerms(note);
    if (terms.isEmpty) return const [];
    final shared = <int, int>{};
    for (final term in terms) {
      for (final row in _stmt(
        'select f.rowid as rowid from docs_fts f join docs d on d.rowid = f.rowid '
        "where docs_fts match ? and d.kind = 'note' and d.status = 'active' limit 500",
      ).select(['"$term"'])) {
        final rowid = row['rowid'] as int;
        shared.update(rowid, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final out = <SimilarNote>[];
    for (final MapEntry(key: rowid, value: count) in shared.entries) {
      if (count < minShared) continue;
      final rows = _stmt('select * from docs where rowid = ?').select([rowid]);
      if (rows.isEmpty) continue;
      final doc = IndexedDoc.fromRow(rows.first);
      if (doc.id == excludeId || doc.id == note.id) continue;
      if (topic != null && doc.topicPath != topic) continue; // 주제 경로(구역/주제)로 본다: 구역이 다르면 다른 주제
      out.add(SimilarNote(doc: doc, shared: count, terms: terms.length));
    }
    // 점수가 같으면 최근에 고친 노트가 먼저 (지금 쓰는 결정일 가능성이 크다)
    out.sort((a, b) {
      final byShared = b.shared.compareTo(a.shared);
      return byShared != 0 ? byShared : b.doc.mtime.compareTo(a.doc.mtime);
    });
    return out.take(limit).toList();
  }

  /// 노트의 핵심 조각 상위 [limit]개 (tf × log(N/df)).
  List<String> keyTerms(Note note, {int limit = 5}) {
    final text = '${note.title}\n${note.summary}\n${note.body}';
    final original = toNfc(text).toLowerCase();
    // 원문에 붙어 있는 두 글자 쌍. 경계 조각(띄어쓰기를 건너 생긴 조각)은 여기 없다.
    // 예전에는 조각마다 `original.contains`로 본문 전체를 훑어 길이의 제곱에 가깝게 느려졌다 (11/11 검토 O-9·K 코어 14).
    final runes = original.runes.toList();
    final pairs = <String>{
      for (var i = 0; i + 1 < runes.length; i++)
        String.fromCharCodes([runes[i], runes[i + 1]]),
    };
    final counts = <String, int>{};
    for (final gram in toBigrams(text).split(' ')) {
      final length = gram.runes.length;
      if (length < 2) continue;
      // 두 글자 조각만 경계일 수 있다 (영어 단어는 원문의 한 낱말이다).
      if (length == 2 ? !pairs.contains(gram) : !original.contains(gram)) {
        continue; // 경계 조각 제외
      }
      counts.update(gram, (n) => n + 1, ifAbsent: () => 1);
    }
    if (counts.isEmpty) return const [];
    final vocab = _vocab;
    final total =
        vocab?.total ??
        (_db
                    .select(
                      "select count(*) as n from docs where kind = 'note'",
                    )
                    .first['n']
                as int)
            .clamp(1, 1 << 30);
    if (vocab == null) _ensureVocab();
    final scored = <(String, double)>[];
    for (final entry in counts.entries) {
      final int n;
      if (vocab != null) {
        n = vocab.df[entry.key] ?? 1;
      } else {
        final df = _stmt('select doc from docs_vocab where term = ?')
            .select([entry.key]);
        n = df.isEmpty ? 1 : (df.first['doc'] as int);
      }
      if (n >= total && total > 3) continue; // 모든 노트에 나오는 조각은 의미 없음
      scored.add((entry.key, entry.value * log((total + 1) / n)));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (term, _) in scored.take(limit)) term];
  }

  var _hasVocab = false;

  /// 대량 색인 동안만 쓰는 조각별 문서 수.
  ({Map<String, int> df, int total})? _vocab;

  void _loadVocab() {
    _ensureVocab();
    _vocab = (
      df: {
        for (final row in _db.select('select term, doc from docs_vocab'))
          row['term'] as String: row['doc'] as int,
      },
      total:
          (_db
                      .select(
                        "select count(*) as n from docs where kind = 'note'",
                      )
                      .first['n']
                  as int)
              .clamp(1, 1 << 30),
    );
  }

  void _ensureVocab() {
    if (_hasVocab) return;
    _db.execute(
      'create virtual table if not exists temp.docs_vocab using fts5vocab(main, docs_fts, row)',
    );
    _hasVocab = true;
  }

  /// 모든 연결 (그래프용). 추천 연결은 이미 `[[링크]]`로 이어진 쌍과 거절한 쌍을 뺀다.
  List<NoteLink> links({Set<(String, String)> dismissed = const {}}) {
    final manual = [
      for (final row in _db.select(
        'select f.id as from_id, t.id as to_id from link_targets l '
        'join docs f on f.rowid = l.from_rowid '
        'join doc_names n on n.name = l.target '
        'join docs t on t.rowid = n.doc_rowid '
        'where f.rowid != t.rowid group by f.id, t.id',
      ))
        NoteLink(
          fromId: row['from_id'] as String,
          toId: row['to_id'] as String,
          kind: 'manual',
        ),
    ];
    final pairs = {
      for (final link in manual) ...[
        (link.fromId, link.toId),
        (link.toId, link.fromId),
      ],
    };
    final suggested = <NoteLink>[];
    for (final row in _db.select(
      'select f.id as from_id, t.id as to_id, s.score as score from suggested_links s '
      'join docs f on f.rowid = s.from_rowid join docs t on t.rowid = s.to_rowid '
      'order by s.score desc',
    )) {
      final from = row['from_id'] as String;
      final to = row['to_id'] as String;
      if (pairs.contains((from, to)) ||
          dismissed.contains((from, to)) ||
          dismissed.contains((to, from))) {
        continue;
      }
      pairs
        ..add((from, to))
        ..add((to, from));
      suggested.add(
        NoteLink(
          fromId: from,
          toId: to,
          kind: 'suggested',
          score: (row['score'] as num).toDouble(),
        ),
      );
    }
    return [...manual, ...suggested];
  }

  /// 대상이 없는 `[[제목]]` (brain lint 죽은 링크).
  List<DeadLink> deadLinks() => [
    for (final row in _db.select(
      'select f.id as from_id, l.label as label from link_targets l '
      'join docs f on f.rowid = l.from_rowid '
      'left join doc_names n on n.name = l.target where n.doc_rowid is null',
    ))
      DeadLink(
        fromId: row['from_id'] as String,
        target: row['label'] as String,
      ),
  ];

  /// 그래프 위치 캐시 (설계서 4.2 `graph_pos`). 다음 실행 때 바로 그린다.
  Map<String, Point<double>> graphPositions() => {
    for (final row in _db.select('select id, x, y from graph_pos'))
      row['id'] as String: Point(
        (row['x'] as num).toDouble(),
        (row['y'] as num).toDouble(),
      ),
  };

  /// [base]는 전체 배치를 했을 때만 준다. 그때의 상태를 기록해 두고, 뒤에 배치가 얼마나 나빠졌는지 견준다
  /// (설계서 5.5 "꼬임 막기" v1.3.28).
  void saveGraphPositions(
    Map<String, Point<double>> positions, {
    LayoutBase? base,
  }) {
    _db.execute('begin immediate'); // 쓰기 잠금을 먼저 잡는다: 읽다가 쓰기로 올리면 다른 프로세스와 겹칠 때 기다리지 않고 BUSY가 난다 (K-32)
    try {
      _db.execute('delete from graph_pos');
      final insert = _db.prepare(
        'insert into graph_pos(id, x, y) values (?, ?, ?)',
      );
      for (final e in positions.entries) {
        insert.execute([e.key, e.value.x, e.value.y]);
      }
      insert.close();
      if (base != null) {
        for (final (key, value) in [
          ('layout_version', base.version),
          ('layout_nodes', base.nodes),
          ('layout_links', base.links),
          ('layout_groups', base.groups),
          ('layout_cross', base.crossings),
          ('layout_stray', base.stray),
        ]) {
          _db.execute(
            'insert or replace into index_meta(key, value) values (?, ?)',
            [key, value],
          );
        }
      }
      _db.execute('commit');
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    }
  }

  /// 마지막 전체 배치의 기록. 없으면 null (이 기록을 남기기 전에 만든 배치이거나 아직 배치한 적 없음).
  LayoutBase? graphLayoutBase() {
    final values = {
      for (final row in _db.select(
        "select key, value from index_meta where key like 'layout_%'",
      ))
        row['key'] as String: row['value'] as int,
    };
    if (values.length < 6) return null;
    return LayoutBase(
      version: values['layout_version']!,
      nodes: values['layout_nodes']!,
      links: values['layout_links']!,
      groups: values['layout_groups']!,
      crossings: values['layout_cross']!,
      stray: values['layout_stray']!,
    );
  }

  /// 저장된 위치와 배치 기록을 지운다. 다음에 그래프를 열 때 처음부터 다시 배치한다 ([다시 배치] 버튼).
  void clearGraphLayout() {
    _db.execute('begin immediate'); // 쓰기 잠금을 먼저 잡는다: 읽다가 쓰기로 올리면 다른 프로세스와 겹칠 때 기다리지 않고 BUSY가 난다 (K-32)
    try {
      _db.execute('delete from graph_pos');
      _db.execute("delete from index_meta where key like 'layout_%'");
      _db.execute('commit');
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    }
  }

  /// 제목·별칭으로 노트 찾기 (`[[제목]]` 해석, NFC·대소문자 무시).
  IndexedDoc? byTitle(String title) {
    final rows = _db.select(
      'select d.* from doc_names n join docs d on d.rowid = n.doc_rowid '
      'where n.name = ? limit 1',
      [linkKey(title)],
    );
    return rows.isEmpty ? null : IndexedDoc.fromRow(rows.first);
  }

  /// 원문 검색. 제목 일치에 3배 가중치 (설계서 4.2).
  ///
  /// 모든 검색어가 맞는 결과가 [limit]개보다 적으면, 검색어 중 하나라도 맞는 결과로
  /// 뒤를 채운다 (자연어 질문은 노트에 없는 말이 섞이기 때문).
  ///
  /// [includeDrafts]가 false면 확인 전 초안과 합쳐진 노트를 뺀다 — AI에게 주는 찾기·자동 주입용
  /// (설계서_프롬프트이후 4.1, 합쳐짐은 4.2·4.4).
  /// 사람이 보는 앱 검색은 초안도 보여야 해서 기본은 true다.
  List<IndexedDoc> search(
    String query, {
    int limit = 5,
    bool includeRaw = false,
    Set<String>? kinds,
    String? topic,
    bool includeDrafts = true,
  }) {
    final strict = toBigramQuery(query);
    if (strict == null) return const [];
    final wanted = kinds ?? {'note', if (includeRaw) 'raw'};
    // 주제(뇌) 범위: 그 폴더 노트만 찾는다. 경로 접두로 거른다 — `구역/주제`, 구역 하나 통째(`개발 지식`),
    // 예전 주제 이름 모두 접두다. 구역 없이 주제 이름만 주면(`Flutter`, 옛 스킬) 구역 안 그 이름의 주제도 본다 (설계서_프롬프트이후 5.1).
    final scope = topic == null ? null : toNfc(topic.trim());
    final prefix = scope == null ? null : 'wiki/$scope/';
    final byName = scope != null && !scope.contains('/') && !isZone(scope);
    bool inScope(IndexedDoc d) =>
        d.path.startsWith(prefix!) || (byName && d.zone != null && d.topic.toLowerCase() == scope.toLowerCase());
    List<IndexedDoc> match(String q, int n) {
      final found = _match(q, prefix == null ? n : n * 20, wanted, includeDrafts: includeDrafts);
      return prefix == null ? found : found.where(inScope).take(n).toList();
    }

    final results = match(strict, limit);
    if (results.length < limit) {
      final relaxed = toRelaxedQuery(query);
      if (relaxed != null) {
        final seen = {for (final d in results) d.id};
        for (final doc in match(relaxed, limit)) {
          if (results.length >= limit) break;
          if (seen.add(doc.id)) results.add(doc);
        }
      }
    }
    return results;
  }

  /// 주제 폴더 목록 (빈 폴더 포함, 숨김 폴더 제외). 구역 안 주제는 `구역/주제`, 구역 밖(예전 방식)은 `주제`
  /// (설계서_프롬프트이후 5.1). 구역 폴더 자체는 주제가 아니라 넣지 않는다.
  List<String> topics() {
    final dir = Directory(vault.wikiDir);
    if (!dir.existsSync()) return const [];
    final out = <String>[];
    for (final d in dir.listSync().whereType<Directory>()) {
      final name = toNfc(p.basename(d.path));
      if (name.startsWith('.')) continue;
      if (isZone(name)) {
        out.addAll([for (final t in zoneTopics(name)) '$name/$t']);
      } else {
        out.add(name);
      }
    }
    return out..sort();
  }

  /// 한 구역의 주제 폴더 이름 (빈 폴더 포함). AI가 저장 전에 기존 주제 전체를 본다 (`brain topics`, 설계서_프롬프트이후 5.1).
  List<String> zoneTopics(String zone) {
    final dir = Directory(p.join(vault.wikiDir, zone));
    if (!dir.existsSync()) return const [];
    return [
      for (final d in dir.listSync().whereType<Directory>())
        if (!p.basename(d.path).startsWith('.')) toNfc(p.basename(d.path)),
    ]..sort();
  }

  /// 초안·합쳐짐 거르기는 SQL 안에서 한다: 찾은 뒤 거르면 [limit]개를 못 채운다.
  List<IndexedDoc> _match(String match, int limit, Set<String> kinds, {bool includeDrafts = true}) => _db
      .select(
        'select d.* from docs_fts f join docs d on d.rowid = f.rowid '
        'where docs_fts match ? and d.kind in (${kinds.map((_) => '?').join(', ')}) '
        // 합쳐진 노트도 뺀다: [옛 노트 보관]·[합치기] 뒤에도 AI가 옛 내용을 찾으면 소용이 없다 (설계서_프롬프트이후 4.4)
        "${includeDrafts ? '' : "and d.status not in ('draft', 'merged') "}"
        'order by bm25(docs_fts, 3.0, 1.0) limit ?',
        [match, ...kinds, limit],
      )
      .map(IndexedDoc.fromRow)
      .toList();

  IndexedDoc? byId(String id) {
    final rows = _db.select('select * from docs where id = ?', [id]);
    return rows.isEmpty ? null : IndexedDoc.fromRow(rows.first);
  }

  /// 노트 목록. 정리 대기가 먼저, 그다음 최근 수정 순.
  List<IndexedDoc> notes() => _db
      .select(
        "select * from docs where kind = 'note' "
        "order by case status when 'draft' then 0 else 1 end, mtime desc",
      )
      .map(IndexedDoc.fromRow)
      .toList();

  /// 지금까지 쓴 노트 번호(n_0042의 42) 중 가장 큰 값.
  int maxNoteNumber() => maxNumber('n_');

  /// [prefix]로 시작하는 id(`n_`, `L-`, `T-`)의 가장 큰 번호.
  int maxNumber(String prefix) {
    var max = 0;
    for (final row in _db.select(
      "select id from docs where substr(id, 1, ?) = ?",
      [prefix.length, prefix],
    )) {
      final n =
          int.tryParse((row['id'] as String).substring(prefix.length)) ?? 0;
      if (n > max) max = n;
    }
    return max;
  }

  /// 종류별 문서 목록 (실수 노트·회귀 시험).
  List<IndexedDoc> docsOf(String kind) => _db
      .select('select * from docs where kind = ? order by id', [kind])
      .map(IndexedDoc.fromRow)
      .toList();
}
