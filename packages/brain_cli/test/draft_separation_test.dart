import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 4.1 초안 분리 (설계서_프롬프트이후 4.1, 측정 M2): 확인 전 초안은 AI 찾기·자동 주입에 나오지 않는다.
/// 실제 `brain`을 프로세스로 실행한다. 60번 넘게 부르므로 한 번 컴파일해 쓴다.
void main() {
  late Directory temp;
  late String exe;
  late String vaultRoot;
  late String configPath;
  late String indexDir;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('draft_separation_');
    // sqlite3 빌드 훅 때문에 `dart compile exe`는 안 되고 `dart build cli`를 쓴다 (tool/build_brain.sh와 같음).
    final out = p.join(temp.path, 'build');
    final result = await Process.run(Platform.resolvedExecutable, ['build', 'cli', '-o', out]);
    if (result.exitCode != 0) fail('brain 빌드 실패: ${result.stderr}');
    exe = p.join(out, 'bundle', 'bin', 'brain');
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  setUp(() {
    final dir = Directory(p.join(temp.path, 'case'))..createSync();
    vaultRoot = p.join(dir.path, 'vault');
    final vault = Vault(vaultRoot)..ensure();
    indexDir = p.dirname(vault.indexPath);
    configPath = p.join(dir.path, 'config.json');
    File(configPath).writeAsStringSync(jsonEncode({'vault': vaultRoot}));
  });

  tearDown(() {
    Directory(p.join(temp.path, 'case')).deleteSync(recursive: true);
    final dir = Directory(indexDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<(int, String, String)> brain(List<String> args, {String? stdin, Map<String, String> env = const {}}) async {
    final process = await Process.start(exe, args, environment: {
      'BRAIN_VAULT': vaultRoot,
      'BRAIN_CONFIG': configPath,
      // 이 시험을 Claude Code 안에서 돌려도 바깥 세션이 물려오지 않게 (weakness_cli_test 참고)
      'CLAUDE_CODE_SESSION_ID': '',
      'CLAUDECODE': '',
      'BRAIN_LEGACY': '',
      ...env,
    });
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    return (code, await out, await err);
  }

  String addNote(String title, String summary, {bool draft = false}) {
    final vault = Vault(vaultRoot);
    final index = SearchIndex.open(vault);
    try {
      return NoteStore(vault, index, zoned: true)
          .add(title: title, summary: summary, body: '$summary\n', tags: ['결제', '웹훅'], topic: '개발 지식/결제', draft: draft)
          .$1;
    } finally {
      index.close();
    }
  }

  void confirm(String id) {
    final vault = Vault(vaultRoot);
    final index = SearchIndex.open(vault);
    try {
      NoteStore(vault, index, zoned: true).setStatus(id, NoteStatus.active);
    } finally {
      index.close();
    }
  }

  // 사용자 말투로 바꾼 관련 질문 10개 (L-0008: 규칙·제목과 같은 말이 아니라)
  const questions = [
    '결제 웹훅 재시도 몇 번까지 하기로 했지?',
    '웹훅 실패하면 결제 쪽은 재시도를 어떻게 해?',
    '결제 웹훅 재시도 간격 어떻게 정했더라',
    '토스 결제 웹훅이 안 오면 재시도 몇 번 해야 돼',
    '웹훅 재시도 정책 다시 알려줘 결제 서버 쪽',
    '결제 웹훅 재시도 횟수 바꿨었나?',
    '결제 실패 웹훅 재시도 로직 짜려는데 기준이 뭐였지',
    '웹훅 재시도를 결제에서는 몇 번 하는 게 맞아?',
    '결제 웹훅 재시도할 때 바로 다시 보내도 되나',
    '지난번에 정한 결제 웹훅 재시도 규칙',
  ];

  /// 질문마다 요청 훅과 brain find를 돌려, 초안 id가 AI에게 간 질문 수.
  Future<int> reached(String draftId, {Map<String, String> env = const {}}) async {
    var count = 0;
    for (final q in questions) {
      final (_, hook, _) = await brain(['hook', 'prompt'], stdin: jsonEncode({'prompt': q, 'cwd': temp.path}), env: env);
      final (_, find, _) = await brain(['find', q], env: env);
      if (hook.contains(draftId) || find.contains(draftId)) count++;
    }
    return count;
  }

  test('M2: 틀린 초안 1개 + 관련 질문 10개 — 이전 방식은 초안이 가고, 새 방식은 0번, 확인하면 다시 간다', () async {
    addNote('결제 웹훅 재시도 정책', '결제 웹훅은 3번까지 재시도하고 간격을 늘린다');
    final draft = addNote('결제 웹훅 재시도 횟수 변경', '결제 웹훅은 10번까지 즉시 재시도한다', draft: true);

    final before = await reached(draft, env: {'BRAIN_LEGACY': 'drafts'});
    final after = await reached(draft);
    confirm(draft);
    final confirmed = await reached(draft);
    // ignore: avoid_print
    print('M2 초안이 AI에게 간 질문 수: 이전 방식 $before/10, 새 방식 $after/10, 확인한 뒤 $confirmed/10');

    expect(before, greaterThan(0), reason: '이전 방식에서 초안이 가지 않으면 이 시험은 아무것도 재지 않는다 (L-0006)');
    expect(after, 0);
    expect(confirmed, greaterThan(0), reason: '확인한 노트는 다시 쓰여야 한다');
  });

  test('find 결과가 0개인데 맞는 초안이 있으면 한 줄로 알리고, --drafts면 보인다', () async {
    final draft = addNote('결제 웹훅 재시도 횟수 변경', '결제 웹훅은 10번까지 즉시 재시도한다', draft: true);
    final (code, out, _) = await brain(['find', '결제 웹훅 재시도']);
    expect(code, 0);
    expect(out, isNot(contains(draft)));
    expect(out, contains('확인 전 초안 1개'));
    final (_, withDrafts, _) = await brain(['find', '--drafts', '결제 웹훅 재시도']);
    expect(withDrafts, contains(draft));
  });

  test('brain find에 노트 번호를 주면 그 노트가 나온다 — n_0001·0001·1, 단어가 안 맞아 숨기는 단계에도 안 걸림 (11/14)', () async {
    final note = addNote('결제 웹훅 재시도 규칙', '결제 웹훅은 3번까지 다시 보낸다');
    final digits = note.substring(2);
    for (final q in [note, digits, int.parse(digits).toString()]) {
      final (code, out, _) = await brain(['find', q]);
      expect(code, 0);
      expect(out.trimLeft(), startsWith(note), reason: q);
    }
    final draft = addNote('결제 웹훅 간격', '1분·5분·30분', draft: true);
    final (_, out, _) = await brain(['find', draft]);
    expect(out, isNot(contains('$draft  ')), reason: 'AI용 찾기는 번호로도 확인 전 초안을 내주지 않는다');
  });

  test('상태 문장 알림 (5.10 ③): brain add는 알리고, brain write는 새로 들어온 상태 문장만 알린다', () async {
    final (code, out, _) = await brain(
      ['add', '--title', '결제 웹훅 재시도', '--summary', '3번까지 다시 보낸다', '--tags', '결제', '--topic', '개발 지식/결제', '--new-topic'],
      stdin: '결제 웹훅은 3번까지 다시 보낸다. 운영에서는 아직 안 돌렸다.\n',
    );
    expect(code, 0);
    final id = RegExp(r'(n_\d{4}) 저장함').firstMatch(out)!.group(1)!;
    expect(out, contains('상태 문장 1개'));
    expect(out, contains('"운영에서는 아직 안 돌렸다."'));
    expect(out, contains('--source $id'));

    Future<String> hash() async => RegExp(r'해시 ([0-9a-f]{12})').firstMatch((await brain(['show', id])).$2)!.group(1)!;
    // 원래 있던 상태 문장은 다시 알리지 않는다
    final (_, same, _) = await brain(['write', id, '--expect-hash', await hash()],
        stdin: '결제 웹훅은 3번까지 다시 보낸다. 운영에서는 아직 안 돌렸다.\n간격은 1분이다.\n');
    expect(same, isNot(contains('상태 문장')));
    // 새로 들어온 상태 문장만 알린다
    final (_, added, _) = await brain(['write', id, '--expect-hash', await hash(), '--summary', '3번, 간격은 미정'],
        stdin: '결제 웹훅은 3번까지 다시 보낸다. 운영에서는 아직 안 돌렸다.\n간격은 1분이다.\n');
    expect(added, contains('상태 문장 1개'));
    expect(added, contains('"3번, 간격은 미정"'));
    expect(added, isNot(contains('아직 안 돌렸다')));
    // 상태 문장이 없는 저장은 조용하다
    final (_, quiet, _) = await brain(
      ['add', '--title', '결제 웹훅 간격', '--summary', '1분·5분·30분', '--tags', '결제', '--topic', '개발 지식/결제'],
      stdin: '간격은 1분, 5분, 30분.\n',
    );
    expect(quiet, contains('저장함'));
    expect(quiet, isNot(contains('상태 문장')));
  });

  test('놓친 교정 줍기 (5.10 ①): brain sessions corrections가 사용자 말·앞 AI 답 끝만 보이고, --done 뒤에는 새 말만', () async {
    final home = Directory(p.join(temp.path, 'case', 'home'))..createSync();
    final projects = Directory(p.join(home.path, '.claude', 'projects', '-Users-me-app'))..createSync(recursive: true);
    void writeSession(String id, List<(String, String)> turns) {
      final lines = [
        for (final (role, text) in turns)
          jsonEncode({
            'type': role == 'user' ? 'user' : 'assistant',
            'sessionId': id,
            'cwd': '/Users/me/app',
            'timestamp': '2026-11-10T10:00:00.000Z',
            'message': role == 'user'
                ? {'role': 'user', 'content': text}
                : {
                    'content': [
                      {'type': 'text', 'text': text},
                    ],
                  },
          }),
      ];
      File(p.join(projects.path, '$id.jsonl')).writeAsStringSync(lines.join('\n'));
    }

    writeSession('aaaaaaaa-1111', [
      ('user', '결제 웹훅 고쳐 줘'),
      ('ai', '고쳤습니다. 배포는 직접 실행해 주세요.'),
      ('user', '너가 할 수 있잖아 그냥 너가 해'),
      ('user', '<agent-message from="x">다른 세션이 보낸 글</agent-message>'),
    ]);
    writeSession('bbbbbbbb-2222', [
      ('user', '지금 대화'),
      ('ai', '네'),
      ('user', '지금 대화 둘'),
    ]);
    final env = {'HOME': home.path, 'CLAUDE_CODE_SESSION_ID': 'bbbbbbbb-2222'};

    final (code, out, _) = await brain(['sessions', 'corrections', '--since', 'all'], env: env);
    expect(code, 0);
    expect(out, contains('[aaaaaaaa #2] AI 끝: "고쳤습니다. 배포는 직접 실행해 주세요."'));
    expect(out, contains('사용자: "너가 할 수 있잖아 그냥 너가 해"'));
    expect(out, isNot(contains('다른 세션이 보낸 글')), reason: '사람이 친 말이 아닌 줄은 보이지 않는다');
    expect(out, isNot(contains('지금 대화')), reason: '지금 진행 중인 세션은 뺀다');
    expect(out, contains('--done aaaaaaaa:3'));
    expect(out, contains('(이것이 마지막)'));

    // 쪽 나누기: 한 쪽에 하나만
    final (_, page, _) = await brain(['sessions', 'corrections', '--since', 'all', '--max-chars', '40'], env: env);
    expect(page, contains('--done aaaaaaaa:1'));
    expect(page, contains('남은 세션 1개·문장 2개'));

    final (doneCode, done, _) = await brain(['sessions', 'corrections', '--done', 'aaaaaaaa:3'], env: env);
    expect(doneCode, 0);
    expect(done, contains('세션 1개'));
    final (_, after, _) = await brain(['sessions', 'corrections', '--since', 'all'], env: env);
    expect(after, contains('훑을 새 사용자 말이 없습니다'));

    // 세션이 이어지면 늘어난 말만
    writeSession('aaaaaaaa-1111', [
      ('user', '결제 웹훅 고쳐 줘'),
      ('ai', '고쳤습니다. 배포는 직접 실행해 주세요.'),
      ('user', '너가 할 수 있잖아 그냥 너가 해'),
      ('user', '<agent-message from="x">다른 세션이 보낸 글</agent-message>'),
      ('ai', '알겠습니다.'),
      ('user', '내부 번호 말고 쉬운 말로 써'),
    ]);
    final (_, more, _) = await brain(['sessions', 'corrections', '--since', 'all'], env: env);
    expect(more, contains('[aaaaaaaa #4] AI 끝: "알겠습니다."'));
    expect(more, isNot(contains('너가 할 수 있잖아')));
  });

  test('brain show의 연결 줄에 초안 제목이 나오지 않는다 (이전 방식이면 나온다)', () async {
    final draft = addNote('결제 웹훅 재시도 횟수 변경', '결제 웹훅은 10번까지 즉시 재시도한다', draft: true);
    final vault = Vault(vaultRoot);
    final index = SearchIndex.open(vault);
    final String confirmed;
    try {
      confirmed = NoteStore(vault, index, zoned: true)
          .add(title: '결제 웹훅 재시도 정책', summary: '3번까지', body: '관련: [[결제 웹훅 재시도 횟수 변경]]\n', topic: '개발 지식/결제')
          .$1;
    } finally {
      index.close();
    }
    final (_, legacy, _) = await brain(['show', confirmed], env: {'BRAIN_LEGACY': 'drafts'});
    expect(legacy, contains(draft), reason: '링크가 이어지지 않으면 이 시험은 아무것도 재지 않는다');
    final (_, now, _) = await brain(['show', confirmed]);
    expect(now, isNot(contains(draft)));
  });

  test('AI 세션에서 부른 brain add는 --draft가 없어도 초안, 사람이 부르면 그대로', () async {
    const body = '결제 웹훅 재시도는 3번이다.\n';
    final args = ['add', '--title', '웹훅 노트', '--summary', '요약', '--topic', '개발 지식/결제'];
    final (code, out, err) = await brain(args, stdin: body, env: {'CLAUDECODE': '1'});
    expect(code, 0, reason: err);
    expect(out, contains('정리 대기'));
    final (code2, out2, err2) = await brain([...args.sublist(0, 2), '웹훅 노트 2', ...args.sublist(3)], stdin: body);
    expect(code2, 0, reason: err2);
    expect(out2, isNot(contains('정리 대기')));
  });
}
