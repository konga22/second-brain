import 'dart:io';
import 'dart:isolate';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 데이터 안전 전체 감사 (Fable 5.2 작업 지시서 2번, 11/14): 이미 들어간 기능들이 맞물리는 "A 다음에 B"에서
/// 노트를 잃거나 겹치게 하지 않는지 본다. 11/13 검토(n_0092)가 고친 것(옮기기 ↔ 되돌리기, 합치기 중 실패,
/// 정리 보드 [되돌리기])은 다시 넣지 않았다 — `folder_move_safety_test`·`merge_draft_test`·`ai_edits_test`에 있다.
///
/// 시험은 모두 **안전한 결과**를 기대한다. 지금 깨지는 시험(재현된 버그)은 [openBug]로 표시해 평소 실행에서는
/// 건너뛴다 — 빨간 시험이 다른 실패를 가리지 않게. 재현하려면
/// `AUDIT_REPRO=1 dart test test/data_safety_audit_test.dart` (실패가 곧 재현이다). 고치면 `skip:`을 뗀다.
final openBug = Platform.environment['AUDIT_REPRO'] == '1'
    ? null
    : '재현된 버그(고치기 전) — AUDIT_REPRO=1로 돌리면 실패한다';

void main() {
  late Directory temp;
  late Vault vault;
  late String indexPath;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('data_safety_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    indexPath = p.join(temp.path, 'index.db');
    index = SearchIndex.open(vault, path: indexPath);
    store = NoteStore(vault, index, zoned: true);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  List<File> wikiFiles() => [
    for (final f in Directory(vault.wikiDir).listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.md') && p.basename(f.path) != 'index.md') f,
  ];

  /// 같은 번호의 노트 파일이 지식 폴더(wiki)에 몇 개인가. 색인이 아니라 파일을 센다(색인은 겹치면 f_ 번호로 숨긴다).
  int filesWithId(String id) => [
    for (final f in wikiFiles())
      if (RegExp('^id: "?${RegExp.escape(id)}"?\$', multiLine: true).hasMatch(f.readAsStringSync())) f,
  ].length;

  /// 지식 폴더(wiki)에 남아 있는 노트 글 전체. 휴지통·되돌리기 사본(_meta)은 넣지 않는다.
  String wikiText() => wikiFiles().map((f) => f.readAsStringSync()).join('\n=====\n');

  /// 묶음을 되돌려 본다. 거절(ArgumentError)도 안전한 결과다 — 거절했으면 false.
  bool tryUndo(String batch) {
    try {
      undoBatch(vault, batch);
      index.sync();
      return true;
    } on ArgumentError {
      return false;
    }
  }

  group('되돌리기가 경로만 보고 덮거나 치운다 (그 묶음이 남긴 파일인지 보지 않는다)', () {
    test('버린 노트 자리에 같은 이름의 새 노트가 생긴 뒤 "버리기"를 되돌려도 새 노트는 남는다', () {
      final (old, oldPath) = store.add(
        title: 'SQLite 동시 열기',
        summary: '틀린 초안',
        body: '틀린 초안 내용.\n',
        topic: '개발 지식/SQLite',
        draft: true,
        batch: 'b_add_old',
      );
      store.delete(old, batch: 'b_discard'); // 정리 보드 [버림]
      final (fresh, freshPath) = store.add(
        title: 'SQLite 동시 열기',
        summary: '다시 저장한 노트',
        body: '다시 저장한 맞는 내용.\n',
        topic: '개발 지식/SQLite',
        batch: 'b_add_new',
      );
      expect(freshPath, oldPath, reason: '시험 전제: 새 노트가 버린 노트와 같은 파일 자리에 생긴다');

      tryUndo('b_discard'); // 설정 [되돌리기] 또는 brain undo

      expect(wikiText(), contains('다시 저장한 맞는 내용.'), reason: '새 노트가 버린 노트의 옛 내용으로 덮였다 (휴지통에도 없다)');
      expect(index.byId(fresh), isNotNull, reason: '새 노트 $fresh가 색인에서 사라졌다');
    }, skip: openBug);

    test('세션 묶음을 되돌릴 때, 그 자리에 지금 있는 다른 세션의 노트를 휴지통으로 보내지 않는다', () {
      final (a, pathA) = store.add(title: '배포 요일', summary: '화·목', body: 'A 세션이 저장한 내용.\n', topic: '프로젝트/쇼핑몰', draft: true, batch: 's_aaaaaaaa');
      store.delete(a, batch: 'b_discard');
      final (b, pathB) = store.add(title: '배포 요일', summary: '화·목·금', body: 'B 세션이 저장한 내용.\n', topic: '프로젝트/쇼핑몰', draft: true, batch: 's_bbbbbbbb');
      expect(pathB, pathA, reason: '시험 전제: 같은 파일 자리');

      tryUndo('s_aaaaaaaa'); // brain undo s_<A 세션 앞 8자>

      expect(wikiText(), contains('B 세션이 저장한 내용.'), reason: 'A 세션 묶음을 되돌렸는데 B 세션의 노트가 지식 폴더에서 빠졌다');
      expect(index.byId(b), isNotNull);
    }, skip: openBug);

    test('고친 뒤 제목을 바꾼 노트: 앞의 고침을 되돌려도 같은 번호의 노트가 둘이 되지 않는다', () {
      final (id, _) = store.add(title: '배포 요일', summary: '화·목', body: '화·목 배포.\n', topic: '프로젝트/쇼핑몰', batch: 'b_add');
      store.write(id, '화·목·금 배포.\n', expectHash: store.read(id)!.$3, batch: 'b_write');
      final (_, note, hash) = store.read(id)!;
      store.update(id, expectHash: hash, title: '배포 일정 결정', summary: note.summary, body: note.body, batch: 'b_rename');
      expect(filesWithId(id), 1);

      tryUndo('b_write');

      expect(filesWithId(id), 1, reason: '옛 파일 이름으로 고치기 전 노트가 다시 생겨 같은 번호($id)가 두 파일이다');
    }, skip: openBug);

    test('제목을 바꾼 뒤 고친 노트: 제목 바꾸기를 되돌려도 뒤의 고침이 지식 폴더에서 사라지지 않는다', () {
      final (id, _) = store.add(title: '배포 요일', summary: '화·목', body: '화·목 배포.\n', topic: '프로젝트/쇼핑몰', batch: 'b_add');
      final (_, note, hash) = store.read(id)!;
      store.update(id, expectHash: hash, title: '배포 일정 결정', summary: note.summary, body: note.body, batch: 'b_rename');
      store.write(id, '제목을 바꾼 뒤 고친 내용.\n', expectHash: store.read(id)!.$3, batch: 'b_write');

      tryUndo('b_rename');

      expect(wikiText(), contains('제목을 바꾼 뒤 고친 내용.'), reason: '뒤의 고침이 휴지통으로 가고 옛 내용만 남았다');
      tryUndo('b_write');
      expect(filesWithId(id), 1, reason: '이어서 뒤 묶음을 되돌리자 같은 번호가 두 파일이 됐다');
    }, skip: openBug);

    test('고친 뒤 버린 노트: 앞의 고침을 되돌려도 버린 노트가 지식 폴더에 되살아나지 않는다', () {
      final (id, _) = store.add(title: '옛 초안', summary: '요약', body: '처음.\n', topic: '공부/운영체제', draft: true, batch: 'b_add');
      store.write(id, '고침.\n', expectHash: store.read(id)!.$3, batch: 'b_write');
      store.delete(id, batch: 'b_discard');
      expect(filesWithId(id), 0);

      tryUndo('b_write');

      expect(filesWithId(id), 0, reason: '사용자가 버린 노트가 고치기 전 내용으로 다시 생겼다');
    }, skip: openBug);

    test('[알려진 약점, 기능검토 1-5] 같은 노트를 두 번 고친 뒤 앞 묶음을 되돌려도 뒤의 고침은 남는다', () {
      final (id, _) = store.add(title: '토큰 만료', summary: '15분', body: '15분.\n', topic: '개발 지식/로그인', batch: 'b_add');
      store.write(id, '첫째 고침: 30분.\n', expectHash: store.read(id)!.$3, batch: 'b_first');
      store.write(id, '둘째 고침: 60분.\n', expectHash: store.read(id)!.$3, batch: 'b_second');

      tryUndo('b_first');

      expect(store.read(id)!.$2.body, contains('둘째 고침: 60분.'), reason: '앞 묶음을 되돌리자 뒤의 고침까지 사라졌다 (사본도 없다)');
    }, skip: openBug);

    test('AI가 할 일을 추천한 뒤 사용자가 적은 할 일은, 추천 묶음을 되돌려도 남는다', () {
      final todos = TodoStore(vault, index);
      vault.ensure();
      todos.suggest('AI가 추천한 일', batch: 'b_ai');
      todos.add('사용자가 직접 적은 일', batch: 'b_user');

      tryUndo('b_ai');

      final file = File(p.join(vault.root, 'todos.md'));
      expect(file.existsSync() ? file.readAsStringSync() : '', contains('사용자가 직접 적은 일'), reason: '할 일 파일이 통째로 추천 전 상태가 됐다');
    }, skip: openBug);

    test('새 노트를 만든 묶음을 되돌렸다고 하면(거절하지 않았으면) 그 노트는 지식 폴더에 없다', () {
      final (id, _) = store.add(title: '배포 요일', summary: '화·목', body: '화·목 배포.\n', topic: '프로젝트/쇼핑몰', batch: 'b_add');
      final (_, note, hash) = store.read(id)!;
      store.update(id, expectHash: hash, title: '배포 일정 결정', summary: note.summary, body: note.body, batch: 'b_rename');

      final undone = tryUndo('b_add');

      if (undone) {
        expect(filesWithId(id), 0, reason: '"되돌림"으로 적혔는데 노트는 그대로 남았다 (다시 되돌릴 수도 없다)');
      }
    }, skip: openBug);
  });

  group('합치기·보관 뒤에 일어나는 일', () {
    test('사진을 붙인 초안을 폴더 깊이가 다른 노트에 합쳐도 사진 링크가 파일을 가리킨다', () {
      final photo = File(p.join(temp.path, 'shot.png'))
        ..writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4, 5, 6, 7, 8]);
      final (target, _) = store.add(title: '결제 웹훅 재시도 규칙', summary: '3번까지', body: '결제 웹훅 재시도는 3번까지 간격을 늘린다.\n', topic: '개발 지식/결제');
      // 구역을 고르지 않은 초안(사람이 터미널·앱에서 저장)은 `wiki/미분류/`에 간다 — 구역 안 노트보다 한 단계 얕다.
      final (draft, draftPath) = store.add(title: '결제 웹훅 설정 화면', summary: '캡처', body: '결제 웹훅 설정 화면 캡처.\n', draft: true, attachments: [photo.path]);
      expect(draftPath, startsWith('wiki/미분류/'));

      store.mergeDraftInto(draft, target);

      final (doc, note, _) = store.read(target)!;
      final links = assetImageLink.allMatches(note.body).toList();
      expect(links, isNotEmpty, reason: '합친 본문에 사진 링크가 없다');
      for (final link in links) {
        final resolved = p.normalize(p.join(p.dirname(p.join(vault.root, doc.path)), link.group(2)!));
        expect(File(resolved).existsSync(), isTrue, reason: '합친 뒤 사진 링크 ${link.group(2)}가 가리키는 파일이 없다 ($resolved)');
      }
    }, skip: openBug);

    test('합쳐진 옛 노트가 가리키는 새 노트를 지우면, 옛 노트가 다시 보이거나 점검이 알려 준다', () {
      final (oldId, _) = store.add(title: '배포 요일 결정', summary: '화·목 배포', body: '배포는 화요일과 목요일에 한다.\n', topic: '프로젝트/쇼핑몰');
      final (newId, _) = store.add(title: '배포 요일 결정 (11월)', summary: '화·목·금 배포', body: '배포는 화요일과 목요일과 금요일에 한다.\n', topic: '프로젝트/쇼핑몰');
      store.markMerged(oldId, into: newId, batch: 'b_archive'); // 정리 보드 [옛 노트 보관]
      store.delete(newId, batch: 'b_delete');

      final seenByAi = index.search('배포 요일', includeDrafts: false).map((d) => d.id);
      final flagged = Linter(vault, index).run().any((i) => i.id == oldId);
      expect(
        seenByAi.contains(oldId) || flagged,
        isTrue,
        reason: '배포 요일 지식이 AI 찾기에서 모두 사라졌는데(옛 노트는 합쳐짐, 새 노트는 휴지통) 점검도 알려 주지 않는다',
      );
    }, skip: openBug);
  });

  group('잠금 없이 읽고 고쳐 쓰는 파일을 동시에 고칠 때', () {
    const workers = 6;
    const each = 15;

    test('할 일 추천을 동시에 넣어도 하나도 사라지지 않는다 (todos.md)', () async {
      vault.ensure();
      final errors = (await Future.wait([for (var w = 0; w < workers; w++) _suggestTodos(vault.root, indexPath, w, each)])).expand((e) => e).toList();
      final lines = File(p.join(vault.root, 'todos.md')).readAsLinesSync().where((l) => l.startsWith('- [ ] 할 일 ')).toSet();
      final lost = workers * each - lines.length;
      expect(
        (lost: lost, errors: errors.length),
        (lost: 0, errors: 0),
        reason: '동시에 넣은 추천 ${workers * each}개 중 $lost개가 사라졌고, 쓰다가 난 오류가 ${errors.length}번이다'
            '${errors.isEmpty ? '' : ' (예: ${errors.first})'}',
      );
    }, skip: openBug);

    test('실수 노트 근거 횟수를 동시에 올려도 덜 세지 않는다 (lessons/L-xxxx.md)', () async {
      final lessons = LessonStore(vault, index);
      final (id, _) = lessons.add(trigger: '커밋하거나 push할 때', action: '매번 허락을 받는다', reason: '사용자 요청', status: LessonStatus.active);
      final errors = (await Future.wait([for (var w = 0; w < workers; w++) _recordEvidence(vault.root, indexPath, id, w, each)])).expand((e) => e).toList();
      expect(
        (kept: lessons.read(id)!.kept, errors: errors.length),
        (kept: workers * each, errors: 0),
        reason: '지킴 ${workers * each}번을 적었는데 덜 세졌거나 쓰다가 오류가 났다${errors.isEmpty ? '' : ' (예: ${errors.first})'}',
      );
    }, skip: openBug);

    test('세션을 읽은 범위를 동시에 적어도 다른 세션의 기록이 사라지지 않는다 (_meta/session_reads.json)', () async {
      vault.ensure();
      await Future.wait([for (var w = 0; w < workers; w++) _recordReads(vault.root, 'session-$w', each)]);
      final reads = SessionReads(vault);
      final missing = [
        for (var w = 0; w < workers; w++)
          if (reads.unread('session-$w', each * 100).isNotEmpty) 'session-$w',
      ];
      expect(missing, isEmpty, reason: '읽었다고 적은 범위가 사라진 세션');
    }, skip: openBug);

    test('다른 연결이 색인을 맞추는 동안 저장해도 오류로 끝나지 않는다 (저장됐는데 실패로 보이면 다시 저장해 중복이 생긴다)', () async {
      for (var i = 0; i < 30; i++) {
        store.add(title: '바탕 노트 $i', summary: '요약', body: '바탕 본문 $i.\n', topic: '공부/바탕');
      }
      // 저장하는 연결 둘(앱 저장·brain add)과 색인만 맞추는 연결 둘(brain find·요청 훅·앱 폴더 감시)
      final results = await Future.wait([
        _addNotesCounting(vault.root, indexPath, 0, 40),
        _addNotesCounting(vault.root, indexPath, 1, 40),
        _syncMany(vault.root, indexPath, 300),
        _syncMany(vault.root, indexPath, 300),
      ]);
      final addErrors = [...results[0], ...results[1]];
      final syncErrors = [...results[2], ...results[3]];
      // 오류로 끝난 저장 가운데 노트 파일은 이미 쓰인 것: 부른 쪽(AI·사용자)은 실패로 알고 다시 저장한다
      final savedButFailed = [
        for (final e in addErrors)
          if (wikiText().contains('title: "${e.split('|').first}"')) e,
      ];
      expect(
        (addErrors: addErrors.length, savedButFailed: savedButFailed.length, syncErrors: syncErrors.length),
        (addErrors: 0, savedButFailed: 0, syncErrors: 0),
        reason: '저장 80번 중 ${addErrors.length}번이 오류로 끝났고 그중 ${savedButFailed.length}번은 노트가 이미 저장된 뒤였다. '
            '색인만 맞추던 쪽 오류 ${syncErrors.length}번${addErrors.isEmpty ? '' : ' (예: ${addErrors.first.split('|').last})'}',
      );
    }, skip: openBug);

    test('[안전 확인] 새 노트를 동시에 저장해도 번호와 파일이 겹치지 않는다 (잠금 안)', () async {
      final ids = (await Future.wait([for (var w = 0; w < 4; w++) _addNotes(vault.root, indexPath, w, 5)])).expand((x) => x).toList();
      index.sync();
      expect(ids.toSet(), hasLength(20), reason: '같은 번호를 받은 노트가 있다');
      expect(wikiFiles(), hasLength(20));
      for (final id in ids) {
        expect(filesWithId(id), 1);
      }
    });

    test('[안전 확인] 놓친 교정 "훑은 곳"을 동시에 적어도 큰 값이 남는다 (잠금 안)', () async {
      vault.ensure();
      await Future.wait([for (var w = 0; w < workers; w++) _markScanned(vault.root, 'session-$w', each)]);
      final state = CorrectionScanState(vault).load();
      expect(state, {for (var w = 0; w < workers; w++) 'session-$w': each});
    });
  });

  group('색인 버전이 바뀐 직후 (다시 만들기를 기다리는 연결)', () {
    test('[안전 확인] 옛 색인을 보는 연결로 실수 노트를 더하고 초안을 확인해도 번호가 겹치지 않고 노트가 그대로다', () {
      final (draft, _) = store.add(title: '확인할 초안', summary: '요약', body: '본문.\n', topic: '공부/운영체제', draft: true);
      final lessons = LessonStore(vault, index);
      final (first, _) = lessons.add(trigger: '커밋할 때', action: '허락을 받는다', reason: '사용자 요청', status: LessonStatus.active);
      // 앱을 새 판으로 바꾼 첫 실행: 화면 스레드는 다시 만들지 않는 연결(rebuildIfOld: false)로 옛 색인을 본다.
      index.db.execute('pragma user_version = ${SearchIndex.schemaVersion - 1}');
      final pending = SearchIndex.open(vault, path: indexPath, rebuildIfOld: false);
      addTearDown(pending.close);
      expect(pending.isRebuildPending, isTrue);

      final (second, _) = LessonStore(vault, pending, syncOnRead: false).add(trigger: '보고할 때', action: '한국어로 쓴다', reason: '사용자 요청');
      NoteStore(vault, pending, zoned: true).setStatus(draft, NoteStatus.active, batch: 'b_confirm');

      expect(second, isNot(first));
      expect(File(p.join(vault.lessonsDir, '$first.md')).readAsStringSync(), contains('커밋할 때'));
      // 백그라운드가 다시 만든 뒤
      final rebuilt = SearchIndex.open(vault, path: indexPath);
      addTearDown(rebuilt.close);
      expect(rebuilt.byId(draft)!.status, NoteStatus.active);
      expect(rebuilt.docsOf('lesson').map((d) => d.id), containsAll([first, second]));
    });
  });
}

// 아래는 isolate에서 도는 일꾼이다. 최상위 함수로 두고 경로·숫자만 넘긴다 (실수 노트 L-0004).

/// 할 일 추천 [count]개를 넣는다. 반환: 쓰다가 난 오류들.
Future<List<String>> _suggestTodos(String root, String indexPath, int worker, int count) => Isolate.run(() {
  final vault = Vault(root);
  final index = SearchIndex.open(vault, path: indexPath);
  final errors = <String>[];
  try {
    final todos = TodoStore(vault, index);
    for (var i = 0; i < count; i++) {
      try {
        todos.suggest('할 일 $worker-$i', batch: 'b_todo_$worker');
      } on Object catch (e) {
        errors.add('$e'.split('\n').first);
      }
    }
  } finally {
    index.close();
  }
  return errors;
});

/// 실수 노트 [id]의 지킴 횟수를 [count]번 올린다. 반환: 쓰다가 난 오류들.
Future<List<String>> _recordEvidence(String root, String indexPath, String id, int worker, int count) => Isolate.run(() {
  final vault = Vault(root);
  final index = SearchIndex.open(vault, path: indexPath);
  final errors = <String>[];
  try {
    final lessons = LessonStore(vault, index);
    for (var i = 0; i < count; i++) {
      try {
        lessons.recordEvidence(id, kept: true, batch: 'b_evidence_$worker');
      } on Object catch (e) {
        errors.add('$e'.split('\n').first);
      }
    }
  } finally {
    index.close();
  }
  return errors;
});

/// 세션 [sessionId]의 축약본을 100자씩 [count]쪽 읽었다고 적는다.
Future<void> _recordReads(String root, String sessionId, int count) => Isolate.run(() {
  final reads = SessionReads(Vault(root));
  for (var i = 0; i < count; i++) {
    try {
      reads.record(sessionId, i * 100, (i + 1) * 100, count * 100);
    } on Object {
      // 임시 파일 이름이 겹쳐 실패한 쓰기도 "기록이 사라진 것"으로 드러난다
    }
  }
});

/// 새 노트 [count]개를 저장한다. 반환: 받은 번호들.
Future<List<String>> _addNotes(String root, String indexPath, int worker, int count) => Isolate.run(() {
  final vault = Vault(root);
  final index = SearchIndex.open(vault, path: indexPath);
  try {
    final store = NoteStore(vault, index, zoned: true);
    return [
      for (var i = 0; i < count; i++)
        store.add(title: '동시 저장 $worker-$i', summary: '요약', body: '본문 $worker-$i.\n', topic: '공부/동시성', batch: 'b_add_$worker').$1,
    ];
  } finally {
    index.close();
  }
});

/// 세션 [sessionId]를 1문장부터 [count]문장까지 훑었다고 차례로 적는다.
Future<void> _markScanned(String root, String sessionId, int count) => Isolate.run(() {
  final state = CorrectionScanState(Vault(root));
  for (var i = 1; i <= count; i++) {
    state.markScanned({sessionId: i});
  }
});

/// 새 노트 [count]개를 저장한다. 반환: 오류로 끝난 저장마다 `제목|오류 첫 줄`.
Future<List<String>> _addNotesCounting(String root, String indexPath, int worker, int count) => Isolate.run(() {
  final vault = Vault(root);
  final index = SearchIndex.open(vault, path: indexPath);
  final errors = <String>[];
  try {
    final store = NoteStore(vault, index, zoned: true);
    for (var i = 0; i < count; i++) {
      final title = '동시 색인 $worker-$i';
      try {
        store.add(title: title, summary: '요약', body: '본문 $worker-$i.\n', topic: '공부/동시성');
      } on Object catch (e) {
        errors.add('$title|${'$e'.split('\n').first}');
      }
    }
  } finally {
    index.close();
  }
  return errors;
});

/// 색인을 [count]번 맞춘다 (`brain find`·요청 훅·앱 폴더 감시가 하는 일). 반환: 오류 첫 줄들.
Future<List<String>> _syncMany(String root, String indexPath, int count) => Isolate.run(() {
  final vault = Vault(root);
  final index = SearchIndex.open(vault, path: indexPath);
  final errors = <String>[];
  try {
    for (var i = 0; i < count; i++) {
      try {
        index.sync();
      } on Object catch (e) {
        errors.add('$e'.split('\n').first);
      }
    }
  } finally {
    index.close();
  }
  return errors;
});
