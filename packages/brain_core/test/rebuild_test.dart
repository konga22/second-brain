import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 색인 다시 만들기 (11/11 독립 검토 K-32 나머지): 원자적이고, 앱 화면 스레드에서 돌지 않는다.
void main() {
  late Directory temp;
  late Vault vault;
  late String dbPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('rebuild_');
    vault = Vault(p.join(temp.path, 'SecondBrain'))..ensure();
    dbPath = p.join(temp.path, 'index.db');
    final index = SearchIndex.open(vault, path: dbPath);
    final store = NoteStore(vault, index, zoned: false);
    for (final (title, topic) in [('웹훅 재시도', '결제'), ('롤백 순서', '배포'), ('배포 요일', '배포')]) {
      store.add(title: title, summary: '$title 요약', body: '$title 본문', topic: topic);
    }
    index.close();
  });

  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+rwx', temp.path]);
    temp.deleteSync(recursive: true);
  });

  int notesIn(String path) {
    final index = SearchIndex.open(vault, path: path);
    try {
      return index.notes().length;
    } finally {
      index.close();
    }
  }

  test('다시 만들다 실패하면 옛 색인이 그대로 남는다', () {
    // 하위 폴더 하나를 읽을 수 없게 해 파일 목록을 모으다 실패하게 한다
    final locked = Directory(p.join(vault.wikiDir, '배포'));
    Process.runSync('chmod', ['000', locked.path]);
    final index = SearchIndex.open(vault, path: dbPath);
    expect(() => index.rebuild(), throwsA(isA<FileSystemException>()));
    index.close();
    Process.runSync('chmod', ['755', locked.path]);
    expect(notesIn(dbPath), 3, reason: '예전에는 지우기가 먼저 확정돼 0개가 됐다');
  });

  test('지식 폴더가 없으면 다시 만들지 않는다 (색인을 비우지 않는다)', () {
    Directory(vault.root).renameSync('${vault.root}.away');
    final index = SearchIndex.open(vault, path: dbPath);
    expect(() => index.rebuild(), throwsA(isA<VaultMissingException>()));
    index.close();
    Directory('${vault.root}.away').renameSync(vault.root);
    expect(notesIn(dbPath), 3);
  });

  test('앱(rebuildIfOld: false)은 옛 버전 색인을 열 때 다시 만들지 않고, 백그라운드가 끝낸 뒤 이어 간다', () {
    // 스키마가 오른 새 버전 앱이 처음 켜진 상황: 색인 버전을 하나 낮춘다
    final old = SearchIndex.open(vault, path: dbPath);
    old.db.execute('pragma user_version = ${SearchIndex.schemaVersion - 1}');
    old.close();

    final app = SearchIndex.open(vault, path: dbPath, rebuildIfOld: false);
    expect(app.isRebuildPending, isTrue);
    expect(app.notes(), hasLength(3), reason: '그동안은 옛 색인으로 보인다');
    File(p.join(vault.wikiDir, '결제', '환불 기한.md')).writeAsStringSync(
      '---\nid: n_0100\ntitle: "환불 기한"\nsummary: "7일"\n---\n\n7일 안에 환불한다.\n',
    );
    expect(app.syncIfStale().added, 0, reason: '화면 스레드의 잦은 확인은 1만 개를 다시 색인하지 않는다');

    // 백그라운드(다른 연결)가 다시 만든다
    final background = SearchIndex.open(vault, path: dbPath);
    expect(background.isRebuildPending, isFalse);
    expect(background.notes(), hasLength(4));
    background.close();

    expect(app.isRebuildPending, isFalse);
    expect(app.sync().added, 0, reason: '다시 만든 색인에 이미 들어 있다');
    expect(app.byId('n_0100'), isNotNull);
    app.close();
  });

  test('쓰기는 기본값으로 연 연결로 한다: 처음 색인 중이어도 다시 만든 뒤 저장한다', () {
    final old = SearchIndex.open(vault, path: dbPath);
    old.db.execute('pragma user_version = 0');
    old.close();
    final app = SearchIndex.open(vault, path: dbPath, rebuildIfOld: false);
    final writer = SearchIndex.open(vault, path: dbPath);
    final (id, _) = NoteStore(vault, writer, zoned: false).add(title: '환불 기한', summary: '7일', body: '7일 안에 환불한다.');
    writer.close();
    expect(app.isRebuildPending, isFalse);
    expect(app.byId(id), isNotNull);
    expect(app.notes(), hasLength(4));
    app.close();
  });
}
