import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../lessons/lesson.dart';
import '../note/note.dart';
import '../note/wiki_links.dart';
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

  /// `wiki/결제/a.md` → `결제`. wiki 바로 아래 파일이면 `미분류`.
  String get topic {
    final parts = p.split(path);
    return parts.length >= 3 ? parts[1] : '미분류';
  }

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
      create table if not exists suggested_links (
        from_rowid integer not null,
        to_rowid integer not null,
        score real not null,
        primary key (from_rowid, to_rowid)
      );
    ''');
    final index = SearchIndex._(vault, db);
    final version = db.select('pragma user_version').first.values.first as int;
    if (version < schemaVersion) {
      index.rebuild();
      db.execute('pragma user_version = $schemaVersion');
    }
    return index;
  }

  /// 색인 표 구조가 바뀌면 올린다. 열 때 낮으면 처음부터 다시 색인한다.
  static const schemaVersion = 5;

  /// 추천 연결 기준: 핵심 단어 5개 중 이만큼 겹치는 노트만 잇는다 (3주차 bench로 조정).
  /// 점수 = 겹친 수 / 핵심 단어 수. 연결 이유를 사람이 읽을 수 있게 하려고 bm25 비율 대신 쓴다.
  static const suggestMinShared = 2;

  /// 노트당 추천 연결 최대 개수 (설계서 5.5).
  static const suggestLimit = 5;

  final Vault vault;
  final Database _db;

  Database get db => _db;

  void close() => _db.close();

  /// 바뀐 md 파일만 다시 색인한다 (수정 시각·크기 → 다르면 해시).
  SyncResult sync() {
    final existing = {
      for (final row in _db.select(
        'select rowid, path, mtime, size, hash from docs',
      ))
        row['path'] as String: row,
    };
    // 1) 지금 있는 파일을 모은다.
    final files = <(String, String, File)>[];
    for (final (dir, kind) in [
      (vault.wikiDir, 'note'),
      (p.join(vault.root, 'raw'), 'raw'),
      (vault.lessonsDir, 'lesson'),
    ]) {
      final root = Directory(dir);
      if (!root.existsSync()) continue;
      for (final entity in root.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.md')) continue;
        final rel = toNfc(p.relative(entity.path, from: vault.root));
        if (p.split(rel).any((part) => part.startsWith('.'))) continue;
        // 자동 생성 목차·검증 기준 파일은 노트가 아니다.
        if (p.basename(rel) == 'index.md') continue;
        if (p.basename(rel).startsWith('_')) continue;
        final docKind = kind == 'lesson' && p.split(rel).contains('tests')
            ? 'test'
            : kind;
        files.add((rel, docKind, entity));
      }
    }
    final seen = {for (final (rel, _, _) in files) rel};
    var added = 0;
    var updated = 0;
    var removed = 0;
    final changed = <int>[];
    _db.execute('begin');
    try {
      // 2) 없어진 파일을 먼저 지운다. 이름이 바뀐 파일(옛 경로 삭제 + 새 경로 추가)이
      //    잠깐이라도 같은 id를 둘 갖지 않게 하려는 순서다.
      for (final entry in existing.entries) {
        if (seen.contains(entry.key)) continue;
        _deleteRow(entry.value['rowid'] as int);
        removed++;
      }
      // 3) 바뀐 파일만 다시 색인한다 (수정 시각·크기 → 다르면 해시).
      for (final (rel, kind, file) in files) {
        final stat = file.statSync();
        final mtime = stat.modified.millisecondsSinceEpoch;
        final old = existing[rel];
        if (old != null && old['mtime'] == mtime && old['size'] == stat.size) {
          continue;
        }
        final content = file.readAsStringSync();
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
          _upsert(rel, kind, content, hash, mtime, stat.size, old?['rowid'] as int?),
        );
        old == null ? added++ : updated++;
      }
      for (final rowid in changed) {
        _suggestFor(rowid);
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
    _db.execute('delete from doc_names');
    _db.execute('delete from link_targets');
    _db.execute('delete from suggested_links');
    final result = sync();
    _db.execute("insert into docs_fts(docs_fts) values('optimize')");
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

  int _upsert(
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
        statusText,
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
    if (kind == 'note') {
      for (final name in {linkKey(note.title), ...note.aliases.map(linkKey)}) {
        if (name.isEmpty) continue;
        _db.execute('insert into doc_names(doc_rowid, name) values (?, ?)', [
          newRowid,
          name,
        ]);
      }
      for (final target in parseWikiLinks(note.body)) {
        _db.execute(
          'insert into link_targets(from_rowid, target, label) values (?, ?, ?)',
          [newRowid, linkKey(target), target],
        );
      }
    }
    return newRowid;
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
  void _suggestFor(int rowid) {
    _db.execute('delete from suggested_links where from_rowid = ?', [rowid]);
    final rows = _db.select(
      "select kind, path from docs where rowid = ? and kind = 'note'",
      [rowid],
    );
    if (rows.isEmpty) return;
    final file = File(p.join(vault.root, rows.first['path'] as String));
    if (!file.existsSync()) return;
    final note = Note.parse(
      file.readAsStringSync(),
      fallbackId: '',
      fallbackTitle: p.basenameWithoutExtension(file.path),
    );
    final terms = keyTerms(note);
    if (terms.length < suggestMinShared) return;
    // 핵심 단어가 몇 개 겹치는지 센다. 핵심 단어는 드문 조각이라 결과가 많지 않다.
    final shared = <int, int>{};
    for (final term in terms) {
      for (final row in _db.select(
        'select f.rowid as rowid from docs_fts f join docs d on d.rowid = f.rowid '
        "where docs_fts match ? and d.kind = 'note' limit 500",
        ['"$term"'],
      )) {
        final other = row['rowid'] as int;
        if (other != rowid) shared.update(other, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final candidates = shared.entries
        .where((e) => e.value >= suggestMinShared)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in candidates.take(suggestLimit)) {
      _db.execute(
        'insert or replace into suggested_links(from_rowid, to_rowid, score) '
        'values (?, ?, ?)',
        [rowid, entry.key, entry.value / terms.length],
      );
    }
  }

  /// 노트의 핵심 조각 상위 [limit]개 (tf × log(N/df)).
  List<String> keyTerms(Note note, {int limit = 5}) {
    final text = '${note.title}\n${note.summary}\n${note.body}';
    final original = toNfc(text).toLowerCase();
    final counts = <String, int>{};
    for (final gram in toBigrams(text).split(' ')) {
      if (gram.runes.length < 2) continue;
      if (!original.contains(gram)) continue; // 경계 조각 제외
      counts.update(gram, (n) => n + 1, ifAbsent: () => 1);
    }
    if (counts.isEmpty) return const [];
    final total =
        (_db.select("select count(*) as n from docs where kind = 'note'").first['n']
                as int)
            .clamp(1, 1 << 30);
    _ensureVocab();
    final scored = <(String, double)>[];
    for (final entry in counts.entries) {
      final df = _db.select(
        'select doc from docs_vocab where term = ?',
        [entry.key],
      );
      final n = df.isEmpty ? 1 : (df.first['doc'] as int);
      if (n >= total && total > 3) continue; // 모든 노트에 나오는 조각은 의미 없음
      scored.add((entry.key, entry.value * log((total + 1) / n)));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (term, _) in scored.take(limit)) term];
  }

  var _hasVocab = false;

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
      DeadLink(fromId: row['from_id'] as String, target: row['label'] as String),
  ];

  /// 그래프 위치 캐시 (설계서 4.2 `graph_pos`). 다음 실행 때 바로 그린다.
  Map<String, Point<double>> graphPositions() => {
    for (final row in _db.select('select id, x, y from graph_pos'))
      row['id'] as String: Point(
        (row['x'] as num).toDouble(),
        (row['y'] as num).toDouble(),
      ),
  };

  void saveGraphPositions(Map<String, Point<double>> positions) {
    _db.execute('begin');
    try {
      _db.execute('delete from graph_pos');
      final insert = _db.prepare('insert into graph_pos(id, x, y) values (?, ?, ?)');
      for (final e in positions.entries) {
        insert.execute([e.key, e.value.x, e.value.y]);
      }
      insert.close();
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
  List<IndexedDoc> search(
    String query, {
    int limit = 5,
    bool includeRaw = false,
    Set<String>? kinds,
  }) {
    final strict = toBigramQuery(query);
    if (strict == null) return const [];
    final wanted = kinds ?? {'note', if (includeRaw) 'raw'};
    final results = _match(strict, limit, wanted);
    if (results.length < limit) {
      final relaxed = toRelaxedQuery(query);
      if (relaxed != null) {
        final seen = {for (final d in results) d.id};
        for (final doc in _match(relaxed, limit, wanted)) {
          if (results.length >= limit) break;
          if (seen.add(doc.id)) results.add(doc);
        }
      }
    }
    return results;
  }

  List<IndexedDoc> _match(String match, int limit, Set<String> kinds) => _db
      .select(
        'select d.* from docs_fts f join docs d on d.rowid = f.rowid '
        'where docs_fts match ? and d.kind in (${kinds.map((_) => '?').join(', ')}) '
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
      final n = int.tryParse((row['id'] as String).substring(prefix.length)) ?? 0;
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
