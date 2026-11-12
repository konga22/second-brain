import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:secondbrain/core/vault_startup.dart';

/// 앱을 켤 때 지식 폴더가 없으면 (11/11 K-33 나머지).
void main() {
  late Directory temp;
  late Vault vault;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vault_start_');
    vault = Vault(p.join(temp.path, 'USB', 'SecondBrain'));
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
    final cache = Directory(p.dirname(vault.indexPath));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  /// 노트 3개를 색인해 둔 뒤 지식 폴더를 지운다 (외장 디스크가 빠진 것과 같다).
  void useThenUnplug() {
    vault.ensure();
    final index = SearchIndex.open(vault);
    final store = NoteStore(vault, index);
    for (final title in ['웹훅 재시도', '롤백 순서', '배포 요일']) {
      store.add(title: title, summary: '$title 요약', body: '$title 본문');
    }
    expect(index.notes(), hasLength(3));
    index.close();
    Directory(vault.root).deleteSync(recursive: true);
  }

  int indexedNotes() {
    final index = SearchIndex.open(vault);
    try {
      return index.db.select("select count(*) as n from docs where kind = 'note'").first['n'] as int;
    } finally {
      index.close();
    }
  }

  test('옛 경로 재현: 켜자마자 폴더를 만들고 동기화하면 색인이 빈다', () {
    useThenUnplug();
    vault.ensure(); // 예전 vaultProvider
    final index = SearchIndex.open(vault);
    index.sync();
    expect(index.notes(), isEmpty, reason: '빈 폴더를 진짜로 보고 색인을 비운다');
    index.close();
  });

  test('쓰던 폴더가 없으면 만들지 않고 묻는다 — 폴더도 색인도 그대로', () {
    useThenUnplug();
    final start = checkVaultAtStart(vault);
    expect(start.isReady, isFalse);
    expect(start.error, isNull);
    expect(Directory(vault.root).existsSync(), isFalse, reason: '빈 폴더를 새로 만들면 안 된다');
    expect(indexedNotes(), 3);
  });

  test('디스크를 다시 연결하면 그대로 열린다', () {
    useThenUnplug();
    expect(checkVaultAtStart(vault).isReady, isFalse);
    Directory(vault.root).createSync(recursive: true);
    expect(checkVaultAtStart(vault).isReady, isTrue);
  });

  test('처음 쓰는 폴더(색인 없음)는 그대로 만든다 (첫 실행)', () {
    final start = checkVaultAtStart(vault);
    expect(start.isReady, isTrue);
    expect(Directory(vault.wikiDir).existsSync(), isTrue);
  });

  test('만들 수 없는 곳이면 예외 화면 대신 까닭과 함께 묻는다', () {
    final blocked = File(p.join(temp.path, 'file'))..writeAsStringSync('x');
    vault = Vault(p.join(blocked.path, 'SecondBrain')); // 파일 아래에는 폴더를 만들 수 없다
    final start = checkVaultAtStart(vault);
    expect(start.isReady, isFalse);
    expect(start.error, isNotNull);
  });
}
