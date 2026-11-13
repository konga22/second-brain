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
      return NoteStore(vault, index)
          .add(title: title, summary: summary, body: '$summary\n', tags: ['결제', '웹훅'], topic: '결제', draft: draft)
          .$1;
    } finally {
      index.close();
    }
  }

  void confirm(String id) {
    final vault = Vault(vaultRoot);
    final index = SearchIndex.open(vault);
    try {
      NoteStore(vault, index).setStatus(id, NoteStatus.active);
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

  test('brain show의 연결 줄에 초안 제목이 나오지 않는다 (이전 방식이면 나온다)', () async {
    final draft = addNote('결제 웹훅 재시도 횟수 변경', '결제 웹훅은 10번까지 즉시 재시도한다', draft: true);
    final vault = Vault(vaultRoot);
    final index = SearchIndex.open(vault);
    final String confirmed;
    try {
      confirmed = NoteStore(vault, index)
          .add(title: '결제 웹훅 재시도 정책', summary: '3번까지', body: '관련: [[결제 웹훅 재시도 횟수 변경]]\n', topic: '결제')
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
    final args = ['add', '--title', '웹훅 노트', '--summary', '요약', '--topic', '결제'];
    final (code, out, err) = await brain(args, stdin: body, env: {'CLAUDECODE': '1'});
    expect(code, 0, reason: err);
    expect(out, contains('정리 대기'));
    final (code2, out2, err2) = await brain([...args.sublist(0, 2), '웹훅 노트 2', ...args.sublist(3)], stdin: body);
    expect(code2, 0, reason: err2);
    expect(out2, isNot(contains('정리 대기')));
  });
}
