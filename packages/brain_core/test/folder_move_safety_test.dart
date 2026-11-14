import 'dart:io';
import 'dart:isolate';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 폴더 정리(설계서_프롬프트이후 5.1) 11/13 검토: 실제 노트를 옮기므로 되돌리기·끊김·동시 쓰기에서 노트가 사라지거나 둘이 되지 않는다.
void main() {
  late Directory temp;
  late Vault vault;
  late String indexPath;
  late SearchIndex index;
  late NoteStore store;
  late NoteStore legacy;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('move_safety_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    indexPath = p.join(temp.path, 'index.db');
    index = SearchIndex.open(vault, path: indexPath);
    store = NoteStore(vault, index, zoned: true);
    legacy = NoteStore(vault, index, zoned: false);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  /// 같은 번호의 노트 파일이 지식 폴더에 몇 개인가 (색인이 아니라 파일을 센다: 색인은 겹치면 f_ 번호로 바꿔 숨긴다).
  int filesWithId(String id) => [
    for (final f in Directory(vault.wikiDir).listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.md') && RegExp('^id: "?${RegExp.escape(id)}"?\$', multiLine: true).hasMatch(f.readAsStringSync())) f,
  ].length;

  test('옮긴 뒤 새 자리를 고친 묶음이 있으면 옮긴 묶음을 되돌리지 않는다: 그 묶음을 먼저 되돌리면 된다', () {
    final (id, oldPath) = legacy.add(title: '옮길 노트', summary: '요약', body: '처음\n', topic: '옛주제', batch: 'b_old');
    store.moveMany([FolderMove(id: id, topic: '개발 지식/새주제')], batch: 'b_mig');
    store.write(id, '옮긴 뒤 고침\n', expectHash: store.read(id)!.$3, batch: 'b_later');
    // 예전에는 b_mig를 되돌리면 고친 노트가 휴지통으로 가고 옛 자리에 고치기 전 노트가 돌아왔다.
    // 이어서 b_later를 되돌리면 새 자리에 노트가 다시 생겨 같은 번호가 둘이었다.
    expect(
      () => undoBatch(vault, 'b_mig'),
      throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', allOf(contains('b_later'), contains('먼저 되돌리')))),
    );
    expect(File(p.join(vault.root, oldPath)).existsSync(), isFalse);
    expect(filesWithId(id), 1);
    undoBatch(vault, 'b_later');
    undoBatch(vault, 'b_mig');
    index.sync();
    expect(filesWithId(id), 1);
    expect(index.byId(id)!.path, oldPath);
    expect(store.read(id)!.$2.body.trim(), '처음');
  });

  test('옮기기 전에 있던 묶음이 새 자리를 건드렸어도(앞선 묶음) 옮긴 묶음은 되돌린다', () {
    final (a, _) = legacy.add(title: '다른 노트', summary: '요약', body: '다른\n', topic: '옛주제', batch: 'b_first');
    // 다른 노트를 새 자리로 먼저 옮겼다가 되돌리지 않고 다시 다른 주제로 옮긴다 → 그 자리를 앞선 묶음이 건드렸다
    store.moveMany([FolderMove(id: a, topic: '개발 지식/새주제', name: '같은 이름')], batch: 'b_early');
    store.moveMany([FolderMove(id: a, topic: '개발 지식/다른주제')], batch: 'b_early2');
    final (b, _) = legacy.add(title: '옮길 노트', summary: '요약', body: '처음\n', topic: '옛주제2', batch: 'b_old');
    store.moveMany([FolderMove(id: b, topic: '개발 지식/새주제', name: '같은 이름')], batch: 'b_mig');
    expect(undoBatch(vault, 'b_mig'), greaterThan(0));
  });

  test('옮기다 끊겨도(예외·Ctrl-C) 이미 옮긴 노트의 옛 묶음은 "경로 바뀜"이다', () {
    final (first, _) = legacy.add(title: '첫 노트', summary: '요약', body: '하나\n', topic: '옛주제', batch: 'b_one');
    final (second, _) = legacy.add(title: '둘째 노트', summary: '요약', body: '둘\n', topic: '옛주제', batch: 'b_two');
    expect(
      () => store.moveMany(
        [FolderMove(id: first, topic: '개발 지식/새주제'), FolderMove(id: second, topic: '개발 지식/새주제')],
        batch: 'b_mig',
        // 첫 노트를 옮긴 뒤 끊긴다 (앱 종료·Ctrl-C 흉내)
        onProgress: (done, _) => throw StateError('끊김'),
      ),
      throwsStateError,
    );
    final batches = {for (final b in recentBatches(vault)) b.id: b};
    expect(batches['b_one']!.isPathMoved, isTrue);
    // 아직 옮기지 않은 노트의 묶음은 그대로 되돌릴 수 있다
    expect(batches['b_two']!.isPathMoved, isFalse);
    expect(() => undoBatch(vault, 'b_one'), throwsA(isA<ArgumentError>()));
    index.sync();
    expect(filesWithId(first), 1);
    // 옮기기를 되돌리면 표시가 풀린다
    undoBatch(vault, 'b_mig');
    expect({for (final b in recentBatches(vault)) b.id: b}['b_one']!.isPathMoved, isFalse);
  });

  test('이전 방식에서 --topic "구역/주제"는 구역을 떼고 주제 폴더에 둔다 (프로젝트-쇼핑몰 폴더를 만들지 않는다)', () {
    final (_, path) = legacy.add(title: '배포 요일 결정', summary: '요약', body: '본문\n', topic: '프로젝트/쇼핑몰');
    expect(path, 'wiki/쇼핑몰/배포 요일 결정.md');
    expect(Directory(p.join(vault.wikiDir, '프로젝트-쇼핑몰')).existsSync(), isFalse);
    // 구역이 아닌 이름의 빗금은 예전처럼 한 폴더 이름으로
    expect(legacy.add(title: '빗금 주제', summary: '요약', body: '본문\n', topic: 'a/b').$2, 'wiki/a-b/빗금 주제.md');
  });

  test('머리말 번호가 비었거나 다른 노트와 겹쳐 f_ 번호를 받은 노트도 옮긴 뒤 번호가 그대로다', () {
    final dir = Directory(p.join(vault.wikiDir, '옛주제'))..createSync(recursive: true);
    File(p.join(dir.path, '빈 번호.md')).writeAsStringSync('---\nid:\ntitle: 빈 번호 노트\nsummary: 요약\n---\n본문\n');
    File(p.join(dir.path, '원본.md')).writeAsStringSync('---\nid: n_0007\ntitle: 원본 노트\nsummary: 요약\n---\n원본\n');
    File(p.join(dir.path, '사본.md')).writeAsStringSync('---\nid: n_0007\ntitle: 사본 노트\nsummary: 요약\n---\n사본\n');
    index.sync();
    final fallback = [for (final d in index.notes()) if (d.id.startsWith('f_')) d.id];
    expect(fallback, hasLength(2));
    final result = store.moveMany([for (final id in fallback) FolderMove(id: id, topic: '개발 지식/모음')]);
    expect(result.errors, isEmpty);
    expect(result.moved, hasLength(2));
    index.sync();
    for (final id in fallback) {
      expect(index.byId(id)?.topicPath, '개발 지식/모음', reason: '$id 번호가 바뀌었다');
    }
    expect(index.byId('n_0007'), isNotNull);
  });

  test('띄어쓰기·대소문자·문장부호만 다른 주제 이름은 기존 주제로 맞춘다 (ClaudeCode = Claude Code)', () {
    store.add(title: '첫 노트', summary: '요약', body: '본문\n', topic: '개발 지식/Claude Code');
    for (final name in ['ClaudeCode', 'claude-code', 'Claude_Code', ' claude  code ', 'Claude·Code']) {
      expect(resolveTopicPath('개발 지식/$name', index.zoneTopics), '개발 지식/Claude Code', reason: name);
    }
    // 구역 없이 주제 이름만 줄 때도
    expect(resolveTopicPath('claudecode', index.zoneTopics), '개발 지식/Claude Code');
    // 글자가 다르면 다른 주제다
    expect(resolveTopicPath('개발 지식/Claude', index.zoneTopics), '개발 지식/Claude');
    expect(topicKey('Claude Code'), topicKey('claude_code'));
  });

  group('지식 폴더 잠금', () {
    test('같은 앱(프로세스) 안 다른 isolate끼리도 잠금을 기다린다', () async {
      final ready = ReceivePort();
      final holder = _holdLockInIsolate(vault.root, ready.sendPort);
      await ready.first;
      final watch = Stopwatch()..start();
      withVaultLock(vault, () {});
      watch.stop();
      await holder;
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(250));
    });

    test('옮기는 중에 고치면 옮긴 뒤 새 자리를 고친다: 옛 자리에 노트가 다시 생기지 않는다', () async {
      final (id, oldPath) = legacy.add(title: '고칠 노트', summary: '요약', body: '처음\n', topic: '옛주제');
      final hash = store.read(id)!.$3;
      final ready = ReceivePort();
      // 다른 isolate가 잠금을 쥔 채 잠시 뒤 옮긴다 (앱 [폴더 정리]의 백그라운드 덩어리 흉내)
      final mover = _moveWhileLockedInIsolate(vault.root, indexPath, id, ready.sendPort);
      await ready.first;
      final watch = Stopwatch()..start();
      store.write(id, '옮기는 중에 고침\n', expectHash: hash);
      watch.stop();
      final newPath = await mover;
      // 예전에는 잠금 없이 바로 옛 자리에 썼다: 옮기기와 엇갈리면 옛 자리에 같은 노트가 다시 생겼다
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(250));
      expect(File(p.join(vault.root, oldPath)).existsSync(), isFalse);
      expect(File(p.join(vault.root, newPath)).readAsStringSync(), contains('옮기는 중에 고침'));
      expect(filesWithId(id), 1);
    });
  });
}

// isolate로 보내는 클로저는 최상위 함수 안에서 만든다: main 안 클로저는 색인 연결까지 잡아 보낼 수 없다 (실수 노트 L-0004).
Future<void> _holdLockInIsolate(String root, SendPort ready) => Isolate.run(() {
  withVaultLock(Vault(root), () {
    ready.send(true);
    sleep(const Duration(milliseconds: 400));
  });
});

Future<String> _moveWhileLockedInIsolate(String root, String indexPath, String id, SendPort ready) => Isolate.run(() {
  final vault = Vault(root);
  final index = SearchIndex.open(vault, path: indexPath);
  try {
    return withVaultLock(vault, () {
      ready.send(true);
      sleep(const Duration(milliseconds: 400));
      return NoteStore(vault, index, zoned: true).move(id, '개발 지식/새주제');
    });
  } finally {
    index.close();
  }
});
