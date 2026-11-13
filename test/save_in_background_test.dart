import 'dart:async';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:secondbrain/core/background_tasks.dart';

/// 앱 안 노트 저장을 백그라운드로 (11/11 검토 O-5).
///
/// 예전에는 편집 창 [저장]이 화면 스레드에서 쓰기 전·후 색인 맞추기와 자동 목차 다시 쓰기를 해
/// 노트 1만 개에서 약 235ms(정식 빌드) 동안 앱이 멈췄다.
///
/// 아래 "화면 멈춤" 시험은 1만 개 폴더가 있을 때만 돈다:
/// SB_PERF_VAULT=<1만 개 폴더> flutter test test/save_in_background_test.dart
void main() {
  late Directory temp;
  late Vault vault;
  late String indexPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('save_bg_');
    vault = Vault(p.join(temp.path, 'vault'))..ensure();
    indexPath = p.join(temp.path, 'index.db');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  (String, String) addDirect(String title, String body) {
    final index = SearchIndex.open(vault, path: indexPath);
    try {
      final store = NoteStore(vault, index);
      final (id, _) = store.add(title: title, summary: '$title 요약', body: body);
      return (id, store.read(id)!.$3);
    } finally {
      index.close();
    }
  }

  String bodyOf(String id) {
    final index = SearchIndex.open(vault, path: indexPath);
    try {
      return NoteStore(vault, index).read(id)!.$2.body.trim();
    } finally {
      index.close();
    }
  }

  test('새 노트를 만들고, 고치고, 다시 읽는다', () async {
    final id = await saveNoteInBackground(
      vault.root,
      indexPath,
      id: null,
      expectHash: null,
      title: '웹훅 재시도',
      summary: '세 번까지',
      body: '세 번까지 재시도한다.',
      tags: const ['결제'],
      aliases: const [],
      batch: newBatchId(),
    );
    expect(bodyOf(id), '세 번까지 재시도한다.');
    final (doc, note, hash) = (await readNoteInBackground(vault.root, indexPath, id))!;
    expect(doc.id, id);
    expect(note.tags, ['결제']);
    await saveNoteInBackground(
      vault.root,
      indexPath,
      id: id,
      expectHash: hash,
      title: note.title,
      summary: note.summary,
      body: '네 번째는 사람이 본다.',
      tags: note.tags,
      aliases: note.aliases,
    );
    expect(bodyOf(id), '네 번째는 사람이 본다.');
    expect(await readNoteInBackground(vault.root, indexPath, 'n_9999'), isNull);
  });

  test('충돌·입력 오류는 같은 예외로 돌아온다 (편집 창이 [덮어쓰기]를 보여 줄 수 있게)', () async {
    final (id, hash) = addDirect('롤백 순서', '이전 버전으로 되돌린다.');
    final index = SearchIndex.open(vault, path: indexPath);
    NoteStore(vault, index).write(id, '밖에서 고친 본문', expectHash: hash);
    index.close();
    await expectLater(
      saveNoteInBackground(
        vault.root,
        indexPath,
        id: id,
        expectHash: hash,
        title: '롤백 순서',
        summary: '요약',
        body: '앱에서 고친 본문',
        tags: const [],
        aliases: const [],
      ),
      throwsA(isA<NoteConflictException>().having((e) => e.copyPath, 'copyPath', contains('conflicts'))),
    );
    expect(bodyOf(id), '밖에서 고친 본문');
    await expectLater(
      saveNoteInBackground(
        vault.root,
        indexPath,
        id: null,
        expectHash: null,
        title: '  ',
        summary: '요약',
        body: '본문',
        tags: const [],
        aliases: const [],
      ),
      throwsA(isA<NoteStoreException>()),
    );
  });

  test('나에 대해의 금지어가 든 노트는 편집 창 저장도 막고, 어느 말인지 예외로 돌아온다 (설계서_프롬프트이후 5.2)', () async {
    const Persona(forbidden: ['연봉']).save(vault);
    Future<String> save(String? id, String? hash, String body) => saveNoteInBackground(
      vault.root,
      indexPath,
      id: id,
      expectHash: hash,
      title: '이직 준비',
      summary: '면접 질문',
      body: body,
      tags: const [],
      aliases: const [],
    );
    await expectLater(
      save(null, null, '올해 연봉협상 메모'),
      throwsA(isA<ForbiddenTermException>().having((e) => e.term, 'term', '연봉')),
    );
    final (id, hash) = addDirect('이직 준비', '자기소개 1분');
    await expectLater(save(id, hash, '희망 연봉 적기'), throwsA(isA<ForbiddenTermException>()));
    expect(bodyOf(id), '자기소개 1분');
  });

  test('노트 패널·사이드바 쓰기: 확정·잇기·옮기기·지우기, 실패는 예외로', () async {
    final (draftId, _) = (() {
      final index = SearchIndex.open(vault, path: indexPath);
      try {
        final store = NoteStore(vault, index);
        final (id, _) = store.add(title: '초안 노트', summary: '확정 전', body: '본문', topic: '결제', draft: true);
        return (id, '');
      } finally {
        index.close();
      }
    })();
    final (otherId, _) = addDirect('롤백 순서', '이전 버전으로');
    Future<void> change(NoteChange change, String id, {String? topic, String? linkTitle}) =>
        changeNoteInBackground(vault.root, indexPath, change: change, id: id, topic: topic, linkTitle: linkTitle, batch: newBatchId());
    IndexedDoc? doc(String id) {
      final index = SearchIndex.open(vault, path: indexPath);
      try {
        index.sync();
        return index.byId(id);
      } finally {
        index.close();
      }
    }

    expect(doc(draftId)!.isDraft, isTrue);
    await change(NoteChange.confirm, draftId);
    expect(doc(draftId)!.isDraft, isFalse);
    await change(NoteChange.appendLink, draftId, linkTitle: '롤백 순서');
    expect(bodyOf(draftId), endsWith('관련: [[롤백 순서]]'));
    await change(NoteChange.move, draftId, topic: '배포');
    expect(doc(draftId)!.topic, '배포');
    await change(NoteChange.delete, otherId);
    expect(doc(otherId), isNull);
    await expectLater(change(NoteChange.confirm, 'n_9999'), throwsA(isA<NoteStoreException>()));
  });

  final perfVault = Platform.environment['SB_PERF_VAULT'];
  test(
    '화면 멈춤: 1만 개 폴더에서 저장하는 동안 화면 스레드가 가장 길게 멈춘 시간',
    () async {
      final copy = p.join(temp.path, 'v10k');
      final cp = await Process.run('cp', ['-R', perfVault!, copy]);
      expect(cp.exitCode, 0, reason: '${cp.stderr}');
      final big = Vault(copy);
      final bigIndex = p.join(temp.path, 'v10k.db');
      final index = SearchIndex.open(big, path: bigIndex);
      index.sync();
      final store = NoteStore(big, index);
      final id = index.notes().first.id;

      /// [save]를 하는 동안 1ms 타이머의 틈이 가장 길었던 시간 = 화면이 멈춘 시간.
      Future<int> longestStall(Future<void> Function() save) async {
        var last = DateTime.now();
        var longest = 0;
        final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
          final now = DateTime.now();
          final gap = now.difference(last).inMilliseconds;
          if (gap > longest) longest = gap;
          last = now;
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await save();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        timer.cancel();
        return longest;
      }

      final before = <int>[];
      final after = <int>[];
      for (var i = 0; i < 3; i++) {
        before.add(
          await longestStall(() async {
            final (_, note, hash) = store.read(id)!;
            store.update(
              id,
              expectHash: hash,
              title: note.title,
              summary: note.summary,
              body: '${note.body}\n화면 스레드 저장 $i\n',
              tags: note.tags,
              aliases: note.aliases,
            );
          }),
        );
        after.add(
          await longestStall(() async {
            final (_, note, hash) = (await readNoteInBackground(copy, bigIndex, id))!;
            await saveNoteInBackground(
              copy,
              bigIndex,
              id: id,
              expectHash: hash,
              title: note.title,
              summary: note.summary,
              body: '${note.body}\n백그라운드 저장 $i\n',
              tags: note.tags,
              aliases: note.aliases,
            );
          }),
        );
      }
      index.close();
      // ignore: avoid_print
      print('가장 길게 멈춘 시간(ms) — 화면 스레드에서 읽기+저장: $before, 백그라운드: $after');
      expect(bodyOf2(big, bigIndex, id), contains('백그라운드 저장 2'));
      expect(after.reduce((a, b) => a > b ? a : b), lessThan(50));
      expect(before.reduce((a, b) => a < b ? a : b), greaterThan(after.reduce((a, b) => a > b ? a : b)));
    },
    skip: perfVault == null ? 'SB_PERF_VAULT 없음 (1만 개 폴더로만 잰다)' : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

String bodyOf2(Vault vault, String indexPath, String id) {
  final index = SearchIndex.open(vault, path: indexPath);
  try {
    return NoteStore(vault, index).read(id)!.$2.body;
  } finally {
    index.close();
  }
}
