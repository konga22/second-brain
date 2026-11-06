import 'package:sqlite3/sqlite3.dart';

import 'bigram.dart';

/// 색인에 필요한 SQLite 기능이 있는지 확인한 결과 (설계서 2.2, 10절).
class SqliteSupport {
  const SqliteSupport({
    required this.version,
    required this.hasFts5,
    required this.hasContentlessDelete,
    required this.bigramSearchWorks,
    this.error,
  });

  final String version;
  final bool hasFts5;
  final bool hasContentlessDelete;
  final bool bigramSearchWorks;
  final String? error;

  bool get isReady => hasFts5 && hasContentlessDelete && bigramSearchWorks;

  List<(String, bool)> get items => [
    ('FTS5', hasFts5),
    ('contentless_delete (SQLite 3.43+)', hasContentlessDelete),
    ('띄어쓰기 무시 2글자 검색', bigramSearchWorks),
  ];
}

/// 메모리 DB에 contentless FTS5 표를 만들어 쓰기·검색·지우기를 실제로 해 본다.
SqliteSupport checkSqliteSupport() {
  final db = sqlite3.openInMemory();
  try {
    final version =
        db.select('select sqlite_version() as v').first['v'] as String;
    final options = db
        .select('pragma compile_options')
        .map((row) => row.values.first as String)
        .toSet();
    final hasFts5 = options.contains('ENABLE_FTS5');
    if (!hasFts5) {
      return SqliteSupport(
        version: version,
        hasFts5: false,
        hasContentlessDelete: false,
        bigramSearchWorks: false,
      );
    }

    db.execute(
      "create virtual table note_fts using fts5("
      "title, body, content='', contentless_delete=1)",
    );
    final insert = db.prepare(
      'insert into note_fts(rowid, title, body) values (?, ?, ?)',
    );
    insert
      ..execute([1, toBigrams('결제 오류'), toBigrams('결제 오류가 나면 웹훅부터 본다')])
      ..execute([2, toBigrams('서버 배포'), toBigrams('배포 전에 환경변수를 확인한다')])
      ..close();

    List<int> search(String query) => db
        .select(
          'select rowid from note_fts where note_fts match ? order by bm25(note_fts)',
          [toBigramQuery(query)],
        )
        .map((row) => row['rowid'] as int)
        .toList();

    final bigramSearchWorks =
        _same(search('결제오류'), [1]) &&
        _same(search('결제 오류'), [1]) &&
        _same(search('환경 변수'), [2]);

    db.execute('delete from note_fts where rowid = 1');
    final hasContentlessDelete = search('결제오류').isEmpty;

    return SqliteSupport(
      version: version,
      hasFts5: true,
      hasContentlessDelete: hasContentlessDelete,
      bigramSearchWorks: bigramSearchWorks,
    );
  } on SqliteException catch (e) {
    return SqliteSupport(
      version: db.select('select sqlite_version() as v').first['v'] as String,
      hasFts5: false,
      hasContentlessDelete: false,
      bigramSearchWorks: false,
      error: e.message,
    );
  } finally {
    db.close();
  }
}

bool _same(List<int> a, List<int> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);
