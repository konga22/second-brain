import 'dart:convert';
import 'dart:io';

import 'package:brain_cli/src/commands/hook_command.dart';
import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 데이터 안전 전체 감사 (Fable 5.2 작업 지시서 2번, 11/14) — 실제 `brain`을 프로세스로 돌려 보는 쪽.
/// 코어 쪽 시험은 `brain_core/test/data_safety_audit_test.dart`.
///
/// 시험은 모두 **안전한 결과**를 기대한다. 감사 때(11/14)는 이 가운데 8개가 고치기 전 코드에서 실패했다 — 같은 날 고친 뒤 모두 통과한다.
void main() {
  late Directory temp;
  late String exe;
  late String home;
  late String vaultRoot;
  late String configPath;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('data_safety_cli_');
    // 여러 번 부르므로 한 번 빌드해 쓴다 (sqlite3 빌드 훅 때문에 `dart build cli`, draft_separation_test와 같다).
    final out = p.join(temp.path, 'build');
    final result = await Process.run(Platform.resolvedExecutable, ['build', 'cli', '-o', out]);
    if (result.exitCode != 0) fail('brain 빌드 실패: ${result.stderr}');
    exe = p.join(out, 'bundle', 'bin', 'brain');
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  setUp(() {
    final dir = Directory(p.join(temp.path, 'case'))..createSync();
    // HOME을 바꿔 색인(~/Library/Caches)과 세션 기록(~/.claude/projects)을 시험 폴더 안에 둔다.
    home = p.join(dir.path, 'home');
    Directory(home).createSync();
    vaultRoot = p.join(dir.path, 'vault');
    Vault(vaultRoot).ensure();
    configPath = p.join(dir.path, 'config.json');
    File(configPath).writeAsStringSync(jsonEncode({'vault': vaultRoot}));
  });

  tearDown(() => Directory(p.join(temp.path, 'case')).deleteSync(recursive: true));

  /// brain을 실행한다. [ai]면 Claude Code 대화 안에서 부른 것처럼 (CLAUDECODE=1).
  Future<(int, String, String)> brain(List<String> args, {String? stdin, bool ai = false}) async {
    final process = await Process.start(exe, args, environment: {
      'HOME': home,
      'BRAIN_VAULT': vaultRoot,
      'BRAIN_CONFIG': configPath,
      // 이 시험을 Claude Code 안에서 돌려도 바깥 세션이 물려오지 않게 (n_0093)
      'CLAUDE_CODE_SESSION_ID': '',
      'CLAUDECODE': ai ? '1' : '',
      'BRAIN_LEGACY': '',
    });
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    return (code, await out, await err);
  }

  List<File> wikiFiles() => [
    for (final f in Directory(p.join(vaultRoot, 'wiki')).listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.md') && p.basename(f.path) != 'index.md') f,
  ];

  int filesWithId(String id) => [
    for (final f in wikiFiles())
      if (RegExp('^id: "?${RegExp.escape(id)}"?\$', multiLine: true).hasMatch(f.readAsStringSync())) f,
  ].length;

  /// 사람이 저장한 정리된 노트 하나. 반환: 번호.
  Future<String> addNote(String title, String body, {String topic = '공부/시험'}) async {
    final (code, out, err) = await brain(['add', '--title', title, '--summary', '$title 요약', '--topic', topic], stdin: body);
    expect(code, 0, reason: err);
    return RegExp(r'n_\d+').firstMatch(out)!.group(0)!;
  }

  Future<String> hashOf(String id) async {
    final (_, out, _) = await brain(['show', id]);
    return RegExp(r'해시 ([0-9a-f]+)').firstMatch(out)!.group(1)!;
  }

  /// 가짜 Claude Code 세션 기록. [turns]는 (사용자 말, AI 답) 짝.
  File writeSession(String id, List<(String, String)> turns) {
    final dir = Directory(p.join(home, '.claude', 'projects', '-Users-me-app'))..createSync(recursive: true);
    final lines = <String>[];
    for (final (i, (user, ai)) in turns.indexed) {
      final time = '2026-11-13T10:${(i + 1).toString().padLeft(2, '0')}';
      lines
        ..add(jsonEncode({
          'type': 'user',
          'sessionId': id,
          'cwd': '/Users/me/app',
          'timestamp': '$time:00.000Z',
          'message': {'role': 'user', 'content': user},
        }))
        ..add(jsonEncode({
          'type': 'assistant',
          'sessionId': id,
          'cwd': '/Users/me/app',
          'timestamp': '$time:30.000Z',
          'message': {
            'content': [
              {'type': 'text', 'text': ai},
            ],
          },
        }));
    }
    return File(p.join(dir.path, '$id.jsonl'))..writeAsStringSync('${lines.join('\n')}\n');
  }

  group('되돌리기 (brain undo)', () {
    test('고친 뒤 제목을 바꾼 노트: 앞의 고침 묶음을 brain undo로 되돌려도 같은 번호가 두 파일이 되지 않는다', () async {
      final id = await addNote('배포 요일', '화·목 배포.\n');
      expect((await brain(['write', id, '--expect-hash', await hashOf(id)], stdin: '화·목·금 배포.\n')).$1, 0);
      final (_, list, _) = await brain(['undo']);
      final writeBatch = list.split('\n').first.split(' ').first;
      expect((await brain(['write', id, '--expect-hash', await hashOf(id), '--title', '배포 일정 결정'])).$1, 0);
      expect(filesWithId(id), 1);

      await brain(['undo', writeBatch]); // 거절해도 되고, 되돌려도 노트가 둘이 되면 안 된다

      expect(filesWithId(id), 1, reason: 'brain undo 뒤 같은 번호($id)의 파일이 둘이다: ${wikiFiles().map((f) => p.basename(f.path)).toList()}');
    });
  });

  group('잠금 없이 읽고 고쳐 쓰는 파일', () {
    test('brain todo suggest 3개를 한꺼번에 불러도(한 메시지에서 도구 3개) 3개가 모두 남는다', () async {
      var lost = 0;
      for (var round = 0; round < 8; round++) {
        final results = await Future.wait([
          for (final name in ['가', '나', '다']) brain(['todo', 'suggest', '할 일 $round-$name', '--source', 'n_0001'], ai: true),
        ]);
        final text = File(p.join(vaultRoot, 'todos.md')).readAsStringSync();
        final kept = ['가', '나', '다'].where((name) => text.contains('할 일 $round-$name')).length;
        // "넣음"이라고 답했는데 파일에 없는 것만 센다
        final said = results.where((r) => r.$2.contains('추천 칸에 넣음')).length;
        lost += said - kept;
      }
      expect(lost, 0, reason: '"추천 칸에 넣음"이라고 답한 24개 가운데 $lost개가 todos.md에 없다');
    });

    test('brain add 4개를 한꺼번에 불러도 모두 끝까지 가고 번호가 겹치지 않는다', () async {
      // 색인 파일은 먼저 만들어 둔다 (노트는 아직 없는 작은 지식 폴더).
      expect((await brain(['index'])).$1, 0);
      final results = await Future.wait([
        for (var i = 0; i < 4; i++)
          brain(['add', '--title', '동시 저장 $i', '--summary', '동시 저장 $i 요약', '--topic', '공부/동시성'], stdin: '서로 다른 본문 $i 번.\n'),
      ]);
      final ids = [for (final r in results) RegExp(r'(n_\d+) 저장함').firstMatch(r.$2)?.group(1)];
      final saved = ids.whereType<String>().toList();
      // 번호는 겹치지 않는다 (지식 폴더 잠금, 11/12 K-26)
      expect(saved.toSet(), hasLength(saved.length));
      for (final id in saved) {
        expect(filesWithId(id), 1);
      }
      // 오류로 끝난 실행: 다른 프로세스와 색인 맞추기가 겹쳤다. 그 노트가 이미 저장됐으면 AI는 실패로 알고 다시 저장한다.
      final text = wikiFiles().map((f) => f.readAsStringSync()).join();
      final failed = [for (final (i, r) in results.indexed) if (r.$1 != 0) (i, r.$3.split('\n').first)];
      final savedButFailed = [for (final (i, _) in failed) if (text.contains('title: "동시 저장 $i"')) i];
      expect(
        failed,
        isEmpty,
        reason: '4개 중 ${failed.length}개가 오류로 끝났고, 그중 ${savedButFailed.length}개는 노트가 이미 저장된 뒤였다',
      );
    });

    test('색인 파일이 아직 없는 새 지식 폴더에서 첫 명령 4개를 한꺼번에 불러도 색인을 여는 데서 실패하지 않는다', () async {
      final results = await Future.wait([for (var i = 0; i < 4; i++) brain(['topics'])]);
      final failed = [for (final r in results) if (r.$1 != 0) r.$3.split('\n').first];
      expect(failed, isEmpty, reason: '읽기 명령 4개 중 ${failed.length}개가 실패했다 (아무것도 쓰기 전이라 노트 손실은 없다)');
    });

    test('[안전 확인] 같은 해시로 동시에 고치면 하나만 되고, 다른 하나는 충돌 사본으로 남는다', () async {
      final id = await addNote('토큰 만료', '15분.\n');
      final hash = await hashOf(id);
      final results = await Future.wait([
        brain(['write', id, '--expect-hash', hash], stdin: '고침 가.\n'),
        brain(['write', id, '--expect-hash', hash], stdin: '고침 나.\n'),
      ]);
      expect(results.where((r) => r.$1 == 0), hasLength(1));
      final conflicts = Directory(p.join(vaultRoot, '_meta', 'conflicts')).listSync();
      expect(conflicts, hasLength(1), reason: '진 쪽의 본문이 충돌 사본에 남아야 한다');
    });
  });

  group('11/14에 들어온 경로', () {
    test('놓친 교정 --done에 실제보다 큰 수를 적어도, 그 세션에서 뒤에 한 말은 다시 훑을 때 보인다', () async {
      const id = 'cafe1234-0000-4000-8000-000000000001';
      final file = writeSession(id, [
        ('로그인 화면 만들어 줘', '만들었습니다. 스크린샷을 붙입니다.'),
        ('스크린샷은 내가 달라고 할 때만 보내', '알겠습니다.'),
        ('다음은 결제 화면', '결제 화면을 만들었습니다.'),
      ]);
      final (_, first, _) = await brain(['sessions', 'corrections']);
      expect(first, contains('--done cafe1234:3'));
      // AI가 끝 줄의 값을 잘못 옮겨 적었다 (3 → 30)
      expect((await brain(['sessions', 'corrections', '--done', 'cafe1234:30'])).$1, 0);
      // 세션이 이어져 사용자 말이 더 생겼다 (교정 포함)
      final more = writeSession('tmp', [('아니 결제는 테스트 키로 먼저 확인하라고 했잖아', '죄송합니다.'), ('앞으로 보고는 표로 해', '네.')]);
      file.writeAsStringSync(more.readAsStringSync().replaceAll('"sessionId":"tmp"', '"sessionId":"$id"'), mode: FileMode.append);
      more.deleteSync();

      final (_, second, _) = await brain(['sessions', 'corrections']);

      expect(second, contains('테스트 키로 먼저 확인'), reason: '실제보다 큰 수가 적힌 세션은 뒤에 한 말(교정)이 다시는 보이지 않는다: $second');
    });

    test('놓친 교정 표시 파일의 값이 숫자가 아니어도 명령이 죽지 않는다', () async {
      writeSession('cafe1234-0000-4000-8000-000000000002', [('하나', '네'), ('둘', '네')]);
      File(p.join(vaultRoot, '_meta', 'correction_scan.json')).writeAsStringSync('{"cafe1234-0000-4000-8000-000000000002": "두 개"}');

      final (_, out, err) = await brain(['sessions', 'corrections']);

      expect(err, isNot(contains('is not a subtype')), reason: '표시 파일을 손으로 고쳤거나 깨졌을 때 놓친 교정 줍기가 통째로 멈춘다');
      expect(out, contains('사용자: "하나"'));
    });

    test('AI 대화 안에서는 적용 중인 실수 노트를 보관하거나 승인 대기로 내리지 못한다 (끄는 것은 사용자가 앱에서)', () async {
      final vault = Vault(vaultRoot);
      final index = SearchIndex.open(vault, path: p.join(temp.path, 'case', 'seed.db'));
      final (id, _) = LessonStore(vault, index).add(
        trigger: '커밋하거나 push할 때',
        action: '매번 사용자에게 허락을 받는다',
        reason: '사용자 요청',
        status: LessonStatus.active,
      );
      index.close();

      final (archiveCode, archiveOut, _) = await brain(['lesson', 'set', id, '--status', 'archived'], ai: true);
      final (_, list, _) = await brain(['lesson', 'list', '--status', 'active']);

      expect(list, contains(id), reason: 'AI가 근거 없이 규칙을 껐다 (종료 코드 $archiveCode, 출력: ${archiveOut.trim()}). 세션 시작 안내에서 빠지고 앱에는 알림이 없다');
      await brain(['lesson', 'set', id, '--status', 'pending'], ai: true);
      expect((await brain(['lesson', 'list', '--status', 'active'])).$2, contains(id), reason: 'AI가 적용 중 규칙을 승인 대기로 내렸다');
    });

    test('PreToolUse 훅은 쓰기 명령(sessions corrections --done)에 붙은 파이프를 떼어 자동 허용하지 않는다', () {
      // 읽기(목록 보기)는 지금처럼 파이프를 떼고 허용한다
      expect(HookCommand.cleanBrainPipe('brain sessions corrections | head -50'), 'brain sessions corrections');
      // --done은 `_meta/correction_scan.json`을 고치는 쓰기다 (sessions mark와 같은 종류, L-0010)
      expect(HookCommand.cleanBrainPipe('brain sessions corrections --done cafe1234:3 | head -5'), isNull);
      expect(HookCommand.cleanBrainPipe('brain sessions corrections --done=cafe1234:3 2>&1'), isNull);
    });

    test('[안전 확인] 목차 표시 파일은 지식 폴더 밖에 있고, 세션 id에 경로 글자가 있어도 그 폴더를 벗어나지 않는다', () async {
      await addNote('결제 웹훅 재시도 규칙', '3번까지 간격을 늘려 재시도.\n', topic: '개발 지식/결제');
      final before = Directory(vaultRoot).listSync(recursive: true).map((e) => e.path).toSet();
      for (final session in ['sess-1', '../../../../escape']) {
        final (code, out, _) = await brain(
          ['hook', 'prompt'],
          stdin: jsonEncode({'prompt': '응모 자동화 프로그램을 설계해줘', 'cwd': '/tmp/x', 'session_id': session}),
        );
        expect(code, 0);
        expect(out, contains('세컨드 브레인 목차'));
      }
      final after = Directory(vaultRoot).listSync(recursive: true).map((e) => e.path).toSet();
      expect(after.difference(before), isEmpty, reason: '훅이 지식 폴더에 파일을 만들었다');
      final shown = Directory(p.join(p.dirname(Vault(vaultRoot).indexPath.replaceFirst(Platform.environment['HOME'] ?? '', home)), 'toc-shown'));
      expect(shown.listSync().map((e) => p.basename(e.path)), containsAll(['sess-1', '____________escape']));
      expect(Directory(p.join(home, 'Library', 'Caches')).listSync(), hasLength(1), reason: '표시 파일이 캐시 폴더 밖에 생겼다');
    });
  });
}
