import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../note/note.dart';
import '../vault/vault.dart';
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
  });

  final String id;

  /// 지식 폴더 기준 상대 경로 (`wiki/결제/결제 웹훅.md`).
  final String path;
  final String kind;
  final String title;
  final String summary;
  final String tags;
  final NoteStatus status;
  final DateTime mtime;
  final String hash;

  bool get isDraft => status == NoteStatus.draft;

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
    mtime: DateTime.fromMillisecondsSinceEpoch(row['mtime'] as int),
    hash: row['hash'] as String,
  );
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

  factory SearchIndex.open(Vault vault, {String? path}) {
    final dbPath = path ?? vault.indexPath;
    Directory(p.dirname(dbPath)).createSync(recursive: true);
    final db = sqlite3.open(dbPath);
    db.execute('pragma journal_mode = wal');
    db.execute('pragma busy_timeout = 2000');
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
    ''');
    return SearchIndex._(vault, db);
  }

  final Vault vault;
  final Database _db;

  Database get db => _db;

  void close() => _db.close();

  /// 바뀐 md 파일만 다시 색인한다 (수정 시각·크기 → 다르면 해시).
  SyncResult sync() {
    final seen = <String>{};
    var added = 0;
    var updated = 0;
    final existing = {
      for (final row in _db.select(
        'select rowid, path, mtime, size, hash from docs',
      ))
        row['path'] as String: row,
    };
    _db.execute('begin');
    try {
      for (final (dir, kind) in [
        (vault.wikiDir, 'note'),
        (p.join(vault.root, 'raw'), 'raw'),
      ]) {
        final root = Directory(dir);
        if (!root.existsSync()) continue;
        for (final entity in root.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File || !entity.path.endsWith('.md')) continue;
          final rel = p.relative(entity.path, from: vault.root);
          if (p.split(rel).any((part) => part.startsWith('.'))) continue;
          seen.add(rel);
          final stat = entity.statSync();
          final mtime = stat.modified.millisecondsSinceEpoch;
          final old = existing[rel];
          if (old != null &&
              old['mtime'] == mtime &&
              old['size'] == stat.size) {
            continue;
          }
          final content = entity.readAsStringSync();
          final hash = contentHash(content);
          if (old != null && old['hash'] == hash) {
            _db.execute('update docs set mtime = ?, size = ? where path = ?', [
              mtime,
              stat.size,
              rel,
            ]);
            continue;
          }
          _upsert(
            rel,
            kind,
            content,
            hash,
            mtime,
            stat.size,
            old?['rowid'] as int?,
          );
          old == null ? added++ : updated++;
        }
      }
      var removed = 0;
      for (final entry in existing.entries) {
        if (seen.contains(entry.key)) continue;
        final rowid = entry.value['rowid'] as int;
        _db.execute('delete from docs_fts where rowid = ?', [rowid]);
        _db.execute('delete from docs where rowid = ?', [rowid]);
        removed++;
      }
      _db.execute('commit');
      return SyncResult(added: added, updated: updated, removed: removed);
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    }
  }

  /// 색인을 지우고 처음부터 다시 만든다.
  SyncResult rebuild() {
    _db.execute('delete from docs_fts');
    _db.execute('delete from docs');
    final result = sync();
    _db.execute("insert into docs_fts(docs_fts) values('optimize')");
    return result;
  }

  void _upsert(
    String rel,
    String kind,
    String content,
    String hash,
    int mtime,
    int size,
    int? rowid,
  ) {
    final fallbackId = kind == 'raw' ? 'r_$hash' : 'f_${contentHash(rel)}';
    final note = Note.parse(
      content,
      fallbackId: fallbackId,
      fallbackTitle: p.basenameWithoutExtension(rel),
    );
    if (rowid != null) {
      _db.execute('delete from docs_fts where rowid = ?', [rowid]);
      _db.execute('delete from docs where rowid = ?', [rowid]);
    }
    // 같은 id가 다른 파일에 이미 있으면(복사한 파일) 경로 기반 id로 바꾼다.
    var id = note.id;
    if (_db.select('select 1 from docs where id = ?', [id]).isNotEmpty) {
      id = 'f_${contentHash(rel)}';
    }
    _db.execute(
      'insert into docs(id, path, kind, title, summary, tags, status, mtime, size, hash) '
      'values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        rel,
        kind,
        note.title,
        note.summary,
        note.tags.join(', '),
        note.status.value,
        mtime,
        size,
        hash,
      ],
    );
    final newRowid = _db.lastInsertRowId;
    final titleText = [note.title, ...note.aliases, ...note.tags].join(' ');
    _db.execute(
      'insert into docs_fts(rowid, title_grams, body_grams) values (?, ?, ?)',
      [
        newRowid,
        toBigrams(titleText),
        toBigrams('${note.summary}\n${note.body}'),
      ],
    );
  }

  /// 원문 검색. 제목 일치에 3배 가중치 (설계서 4.2).
  List<IndexedDoc> search(
    String query, {
    int limit = 5,
    bool includeRaw = false,
  }) {
    final match = toBigramQuery(query);
    if (match == null) return const [];
    final rows = _db.select(
      'select d.* from docs_fts f join docs d on d.rowid = f.rowid '
      'where docs_fts match ? ${includeRaw ? '' : "and d.kind != 'raw'"} '
      'order by bm25(docs_fts, 3.0, 1.0) limit ?',
      [match, limit],
    );
    return rows.map(IndexedDoc.fromRow).toList();
  }

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
  int maxNoteNumber() {
    var max = 0;
    for (final row in _db.select(
      "select id from docs where id like 'n\\_%' escape '\\'",
    )) {
      final n = int.tryParse((row['id'] as String).substring(2)) ?? 0;
      if (n > max) max = n;
    }
    return max;
  }
}
