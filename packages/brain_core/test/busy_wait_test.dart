import 'dart:io';
import 'dart:isolate';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// 다른 연결이 색인 잠금을 오래 쥘 때 (11/12 작업인계 0-4 "첫 색인과 저장이 겹치면 5초 뒤 실패").
/// 처음 색인(다시 만들기)은 한 트랜잭션이라 노트 1만 개에서 12~20초 잠금을 쥔다. 여기서는 7초 쥔다.
void main() {
  late Directory temp;
  late String root;
  late String dbPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('busy_wait_');
    root = p.join(temp.path, 'SecondBrain');
    Vault(root).ensure();
    dbPath = p.join(temp.path, 'index.db');
    SearchIndex.open(Vault(root), path: dbPath).close();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  /// 잠금을 [hold]만큼 쥔 채로 다른 isolate에서 노트를 저장하고, (결과, 걸린 시간)을 돌려준다.
  Future<(String, Duration)> addWhileLocked(Duration hold, Duration? wait) async {
    final holder = sqlite3.open(dbPath);
    holder.execute('pragma busy_timeout = 5000');
    holder.execute('begin immediate');
    final watch = Stopwatch()..start();
    final vaultRoot = root;
    final path = dbPath;
    final waitMs = wait?.inMilliseconds;
    final saving = Isolate.run(() {
      try {
        final vault = Vault(vaultRoot);
        final index = waitMs == null
            ? SearchIndex.open(vault, path: path)
            : SearchIndex.open(vault, path: path, busyTimeout: Duration(milliseconds: waitMs));
        try {
          final (id, _) = NoteStore(vault, index).add(title: '잠금 중 저장', summary: '요약', body: '본문');
          return id;
        } finally {
          index.close();
        }
      } on SqliteException catch (e) {
        return '실패: ${e.message}';
      }
    });
    await Future<void>.delayed(hold);
    holder.execute('commit');
    holder.close();
    final result = await saving;
    return (result, watch.elapsed);
  }

  test('기본(5초)으로는 7초 잠금에 실패한다 — 고치기 전 앱 저장과 같은 조건', () async {
    final (result, _) = await addWhileLocked(const Duration(seconds: 7), null);
    expect(result, startsWith('실패'));
    expect(result, contains('locked'));
  });

  test('busyTimeout을 길게 주면 잠금이 풀린 뒤 저장한다', () async {
    final (result, took) = await addWhileLocked(const Duration(seconds: 7), const Duration(minutes: 2));
    expect(result, matches(RegExp(r'^n_\d{4}$')));
    expect(took.inMilliseconds, greaterThanOrEqualTo(6500), reason: '실제로 기다렸다');
    final index = SearchIndex.open(Vault(root), path: dbPath);
    try {
      expect(index.notes().map((n) => n.title), contains('잠금 중 저장'));
    } finally {
      index.close();
    }
  });
}
