import 'dart:convert';
import 'dart:io';

import 'package:brain_cli/src/commands/hook_command.dart';
import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 요청 훅의 실수 노트 줄 줄이기 (설계서_프롬프트이후 6.4): 이 세션이 세션 시작 목록에서 전체 문장으로 이미 본 규칙은
/// 번호만 알린다. 본 적이 없으면(세션 기록 없음·목록에서 잘림·그 뒤 고침·새 규칙) 지금까지처럼 전체 문장이다.
/// 실제 `brain`을 프로세스로 실행한다.
void main() {
  late Directory temp;
  late String vaultRoot;
  late String configPath;
  late String indexDir;
  late Vault vault;

  const longAction =
      '요소가 있는지·크기·콘솔 오류 0만 보지 않고, 화면 갱신이 도는 환경(앞쪽 탭·실제 시간 대기)에서 실제로 그려진 결과(그려진 점 수·화면 그림)를 '
      '데스크톱과 휴대폰 조건(폭·터치) 모두로 확인한 뒤 보고하고, 확인하지 못한 조건은 확인하지 못했다고 그대로 적는다';

  void writeLesson(String id, String trigger, String action, {String reason = '사용자 규칙'}) {
    File(p.join(vault.lessonsDir, '$id.md')).writeAsStringSync(
      [
        '---',
        'id: $id',
        'status: active',
        'trigger: "$trigger"',
        'action: "$action"',
        'reason: "$reason"',
        'source: explicit',
        'diff: ""',
        'tests: []',
        'created: 2026-11-01',
        'evidence: { kept: 0, recorrected: 0 }',
        '---',
        '',
      ].join('\n'),
    );
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('lesson_remind_');
    vaultRoot = p.join(temp.path, 'vault');
    vault = Vault(vaultRoot)..ensure();
    indexDir = p.dirname(vault.indexPath);
    configPath = p.join(temp.path, 'config.json');
    File(configPath).writeAsStringSync(jsonEncode({'vault': vaultRoot}));
    Directory(vault.lessonsDir).createSync(recursive: true);
    writeLesson('L-0001', '커밋하거나 push할 때', '매번 사용자에게 명시적으로 허락을 받는다');
    writeLesson('L-0002', '실행 중인 프로세스를 끌 때', '끄기 전에 시작 시각·실행 주체를 확인한다', reason: '사용자가 켠 앱을 끈 적이 있음');
    writeLesson('L-0003', '화면 그림이 잘 나온다고 보고할 때', longAction); // 행동이 120자를 넘어 목록에서 잘린다
    SearchIndex.open(vault)
      ..sync()
      ..close();
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
    final dir = Directory(indexDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<String> hook(String event, Map<String, Object?> input, {String? remind}) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', p.join('bin', 'brain.dart'), 'hook', event],
      environment: {
        'BRAIN_VAULT': vaultRoot,
        'BRAIN_CONFIG': configPath,
        // Claude Code 안에서 돌려도 그 세션의 값이 끼어들지 않게 (설계서_프롬프트이후 4.1, n_0093)
        'CLAUDE_CODE_SESSION_ID': '',
        'CLAUDECODE': '',
        'BRAIN_LEGACY': '',
        'BRAIN_LESSON_REMIND': remind ?? '',
      },
    );
    process.stdin.write(jsonEncode(input));
    await process.stdin.close();
    final out = await process.stdout.transform(utf8.decoder).join();
    final err = await process.stderr.transform(utf8.decoder).join();
    expect(await process.exitCode, 0, reason: err);
    return out.trim().isEmpty ? '' : jsonDecode(out)['hookSpecificOutput']['additionalContext'] as String;
  }

  Future<String> start(String session, {String? remind}) =>
      hook('session-start', {'cwd': '/tmp/x', 'session_id': session, 'source': 'startup'}, remind: remind);
  Future<String> ask(String session, String prompt, {String? remind}) =>
      hook('prompt', {'cwd': '/tmp/x', 'session_id': session, 'prompt': prompt}, remind: remind);

  const fullHeader = '사용자의 실수 노트 (이번 요청에 적용):';
  const commitFull = '- L-0001 커밋하거나 push할 때 → 매번 사용자에게 명시적으로 허락을 받는다 (이유: 사용자 규칙)';

  test('방식을 정하지 않으면(기본) 요청 훅은 고치기 전과 글자 하나까지 같다', () async {
    await start('s1');
    final text = await ask('s1', '수정한 거 커밋하고 push 해 줘');
    expect(LessonRemind.fallback, LessonRemind.full, reason: '기본값을 바꾸면 이 시험과 설계서_프롬프트이후 6.4를 함께 고친다');
    expect(text, '$fullHeader\n$commitFull');
  });

  test('ids: 세션 시작 목록에서 본 규칙은 번호 한 줄, 문장은 되풀이하지 않는다', () async {
    final list = await start('s1', remind: 'ids');
    expect(list, contains('  - L-0001 커밋하거나 push할 때 → 매번 사용자에게 명시적으로 허락을 받는다')); // 목록에 전체 문장이 실제로 있다
    final full = await ask('s1', '수정한 거 커밋하고 push 해 줘', remind: 'full');
    final ids = await ask('s1', '수정한 거 커밋하고 push 해 줘', remind: 'ids');
    expect(ids, '세션 시작 안내의 지킬 규칙 가운데 이번 요청에 해당: L-0001');
    expect(ids, isNot(contains('허락')));
    expect(ids.length, lessThan(full.length ~/ 2), reason: 'ids ${ids.length}자, full ${full.length}자');
  });

  test('ids: 여러 규칙이 맞으면 번호를 한 줄에 모은다', () async {
    await start('s1', remind: 'ids');
    final text = await ask('s1', '실행 중인 프로세스 끄고 커밋하고 push 해 줘', remind: 'ids');
    expect(text.split('\n'), hasLength(1));
    expect(text, allOf(contains('L-0001'), contains('L-0002')));
  });

  test('ids: 세션 시작 훅이 돌지 않은 세션(기록 없음)은 전체 문장', () async {
    await start('s1', remind: 'ids');
    expect(await ask('other-session', '수정한 거 커밋하고 push 해 줘', remind: 'ids'), '$fullHeader\n$commitFull');
    // 세션 id가 없거나 파일 이름으로 못 쓰는 값이어도 전체 문장이고, 캐시 폴더 밖에 파일을 만들지 않는다
    await start('../../escape', remind: 'ids');
    expect(await ask('../../escape', '수정한 거 커밋하고 push 해 줘', remind: 'ids'), '$fullHeader\n$commitFull');
    expect(File(p.join(indexDir, '..', 'escape')).existsSync(), isFalse);
    expect(Directory(p.join(indexDir, 'session-lessons')).listSync().map((e) => p.basename(e.path)), ['s1']);
  });

  test('ids: 목록에서 잘린 규칙(행동 120자 넘음)은 계속 전체 문장', () async {
    final list = await start('s1', remind: 'ids');
    expect(list, contains('L-0003'));
    expect(longAction.runes.length, greaterThan(HookCommand.sessionActionMax));
    expect(list, isNot(contains('그대로 적는다')), reason: '목록에서는 잘려 있어야 이 시험이 뜻이 있다');
    final text = await ask('s1', '화면 그림이 잘 나온다고 보고해도 될까', remind: 'ids');
    expect(text, contains('$fullHeader\n- L-0003 화면 그림이 잘 나온다고 보고할 때 → $longAction'));
  });

  test('ids: 잘린 규칙과 본 규칙이 함께 맞으면 전체 문장 + 번호 한 줄', () async {
    await start('s1', remind: 'ids');
    final text = await ask('s1', '화면 그림이 잘 나온다고 보고하고 커밋하고 push 해 줘', remind: 'ids');
    expect(text, contains('- L-0003 화면 그림이 잘 나온다고 보고할 때 → $longAction'));
    expect(text, contains('세션 시작 안내의 지킬 규칙 가운데 이번 요청에 해당: L-0001'));
    expect(text, isNot(contains('- L-0001')));
  });

  test('ids: 세션 시작 뒤 고친 규칙·새로 생긴 규칙은 전체 문장 (AI가 그 문장을 본 적이 없다)', () async {
    await start('s1', remind: 'ids');
    writeLesson('L-0001', '커밋하거나 push할 때', '허락을 받고, 커밋 메시지는 한국어로 쓴다');
    writeLesson('L-0004', '배포할 때', '화요일·목요일에만 한다');
    final changed = await ask('s1', '수정한 거 커밋하고 push 해 줘', remind: 'ids');
    expect(changed, contains('- L-0001 커밋하거나 push할 때 → 허락을 받고, 커밋 메시지는 한국어로 쓴다'));
    expect(changed, isNot(contains('세션 시작 안내의 지킬 규칙')));
    final added = await ask('s1', '오늘 배포할 때 뭐 조심해', remind: 'ids');
    expect(added, contains('- L-0004 배포할 때 → 화요일·목요일에만 한다'));
    // 압축·다시 열기로 세션 시작 훅이 다시 돌면 새 문장을 본 것이 된다
    await start('s1', remind: 'ids');
    expect(await ask('s1', '수정한 거 커밋하고 push 해 줘', remind: 'ids'), '세션 시작 안내의 지킬 규칙 가운데 이번 요청에 해당: L-0001');
  });

  test('none(대조군): 본 규칙은 아무것도 넣지 않고, 못 본 규칙은 전체 문장', () async {
    await start('s1', remind: 'none');
    expect(await ask('s1', '수정한 거 커밋하고 push 해 줘', remind: 'none'), isEmpty);
    expect(await ask('s1', '화면 그림이 잘 나온다고 보고해도 될까', remind: 'none'), contains('- L-0003'));
  });

  test('세션 시작 안내는 방식과 상관없이 같은 글이다 (세션 캐시)', () async {
    final a = await start('s1');
    final b = await start('s2', remind: 'ids');
    final c = await start('s3', remind: 'none');
    expect(a, isNotEmpty);
    expect(b, a);
    expect(c, a);
  });

  // 실수 노트 L-0008: 글자 매칭 기능은 사용자 말투로 바꾼 입력으로 걸릴 것·안 걸릴 것을 함께 본다.
  // 붙는 조건은 바꾸지 않았다 — 같은 요청에 full과 ids가 같은 규칙을 알려야 한다.
  test('ids는 full과 같은 요청에 같은 규칙을 알린다 (말투를 바꾼 요청 8개, 걸릴 것 5·안 걸릴 것 3)', () async {
    await start('s1', remind: 'ids');
    final prompts = {
      '작업한 거 커밋해': true,
      'PR 만들기 전에 push해 둬': true,
      '변경 사항 정리해서 커밋 올려 줘': true,
      '지금 실행 중인 서버 프로세스 좀 꺼 줘': true,
      '백그라운드에서 실행 중인 그 프로세스 끌 수 있어?': true,
      '오늘 날씨 어때': false,
      '이 함수 이름 뭐가 좋을까': false,
      '회의록 요약해 줘': false,
    };
    var hits = 0;
    for (final MapEntry(key: prompt, value: shouldHit) in prompts.entries) {
      final full = await ask('s1', prompt, remind: 'full');
      final ids = await ask('s1', prompt, remind: 'ids');
      final inFull = RegExp(r'L-\d{4}').allMatches(full).map((m) => m.group(0)).toSet();
      final inIds = RegExp(r'L-\d{4}').allMatches(ids).map((m) => m.group(0)).toSet();
      expect(inIds, inFull, reason: prompt);
      expect(inFull.isNotEmpty, shouldHit, reason: prompt);
      if (inFull.isNotEmpty) hits++;
    }
    print('[실수 노트 알림] 걸린 요청 $hits/5, 안 걸려야 할 요청에 걸린 것 0/3');
    expect(hits, 5);
  });

  test('오래된 세션 기록은 세션 시작 때 지운다 (14일)', () {
    final state = SessionLessonState(vault);
    final lesson = LessonStore(vault, SearchIndex.open(vault)).all(status: LessonStatus.active).first;
    state.record('old', [lesson]);
    final old = File(p.join(indexDir, 'session-lessons', 'old'));
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 15)));
    state.record('new', [lesson]);
    expect(old.existsSync(), isFalse);
    expect(state.shown('new'), {lesson.id: SessionLessonState.digest(lesson)});
    expect(state.shown('old'), isEmpty);
  });

  test('목록에서 잘리는 기준이 목록을 만드는 코드와 같다', () {
    final index = SearchIndex.open(vault);
    final lessons = LessonStore(vault, index).all(status: LessonStatus.active);
    final lines = HookCommand.lessonLinesOf(lessons, 0).join('\n');
    for (final lesson in lessons) {
      // 전체 문장으로 보였다고 판단한 규칙은 목록에 그 문장이 그대로 있어야 한다
      expect(lines.contains('${lesson.id} ${lesson.trigger} → ${lesson.action}'), HookCommand.isFullyShown(lesson), reason: lesson.id);
    }
    index.close();
  });
}
