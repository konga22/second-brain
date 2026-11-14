import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 지식 폴더 구조: 고정 구역 + 주제 (설계서_프롬프트이후 5.1). 실제 `brain`을 프로세스로 실행한다.
void main() {
  late Directory temp;
  late String exe;
  late String vaultRoot;
  late String configPath;
  late String indexDir;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('folder_zones_cli_');
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

  const ai = {'CLAUDECODE': '1'};

  Future<(int, String, String)> add(
    String title,
    String? topic, {
    Map<String, String> env = ai,
    String tags = '',
    List<String> extra = const [],
  }) => brain(
    ['add', '--title', title, '--summary', '요약', if (tags.isNotEmpty) ...['--tags', tags], if (topic != null) ...['--topic', topic], ...extra],
    stdin: '$title 본문이다.\n',
    env: env,
  );

  /// 예전 구조 노트 (옮기기 전 폴더 흉내).
  String legacyNote(String topic, String title, {List<String> tags = const []}) {
    final vault = Vault(vaultRoot);
    final index = SearchIndex.open(vault);
    try {
      return NoteStore(vault, index, zoned: false).add(title: title, summary: '요약', body: '$title 본문\n', tags: tags, topic: topic).$1;
    } finally {
      index.close();
    }
  }

  test('AI 저장: 구역/주제가 없거나 모르는 구역이면 거절하고 구역과 주제를 보인다', () async {
    final (code, _, err) = await add('주제 없는 노트', null);
    expect(code, 1);
    expect(err, allOf(contains('구역'), contains('개발 지식'), contains('brain topics')));
    final (code2, _, err2) = await add('모르는 구역 노트', '개발/Flutter');
    expect(code2, 1);
    expect(err2, allOf(contains('"개발"는 없는 구역'), contains('생활·기기')));
    expect(Directory(p.join(vaultRoot, 'wiki', '개발')).existsSync(), isFalse);
  });

  test('구역/주제로 저장: 짧은 이름 파일, 새 주제를 만들면 같은 구역의 기존 주제를 알린다', () async {
    expect((await add('플러터 첫 노트', '개발 지식/Flutter')).$1, 0);
    final (code, out, _) = await add(
      'SQLite 여러 프로세스 동시 열기- busy_timeout을 WAL 설정보다 먼저',
      '개발 지식/SQLite',
      extra: ['--new-topic'],
    );
    expect(code, 0);
    expect(out, contains('wiki/개발 지식/SQLite/SQLite 여러 프로세스 동시 열기.md'));
    expect(out, allOf(contains('새 주제'), contains('Flutter')));
    final (_, again, _) = await add('플러터 두 번째', '개발 지식/Flutter');
    expect(again, isNot(contains('새 주제')));
  });

  test('AI 저장: 구역에 주제가 있는데 없는 주제로 저장하면 한 번 멈추고 그 구역의 주제 전체를 보인다 (--new-topic으로 만든다)', () async {
    // 빈 구역의 첫 주제는 볼 주제가 없어 멈추지 않는다
    expect((await add('클로드 첫 노트', '개발 지식/Claude Code')).$1, 0);
    for (var i = 0; i < 14; i++) {
      Directory(p.join(vaultRoot, 'wiki', '개발 지식', '주제$i')).createSync(recursive: true);
    }
    final (code, out, err) = await add('새 주제 노트', '개발 지식/Riverpod');
    expect(code, 3, reason: err);
    expect(out, isNot(contains('저장함')));
    // 거절 안내에 12개에서 자르지 않고 그 구역의 주제 전체가 나온다
    expect(err, allOf(contains('Riverpod'), contains('Claude Code'), contains('주제0'), contains('주제13'), contains('--new-topic')));
    expect(Directory(p.join(vaultRoot, 'wiki', '개발 지식', 'Riverpod')).existsSync(), isFalse);
    final (again, out2, err2) = await add('새 주제 노트', '개발 지식/Riverpod', extra: ['--new-topic']);
    expect(again, 0, reason: err2);
    expect(out2, contains('wiki/개발 지식/Riverpod/'));
    // 띄어쓰기·대소문자만 다른 이름은 기존 주제다: 멈추지 않고 그 주제에 저장한다
    final (same, out3, err3) = await add('클로드 둘째 노트', '개발 지식/claudecode');
    expect(same, 0, reason: err3);
    expect(out3, contains('wiki/개발 지식/Claude Code/'));
    // 사람이 터미널에서 부르면 멈추지 않는다
    expect((await add('사람 노트', '개발 지식/Dart', env: const {})).$1, 0);
  });

  test('brain topics: 구역마다 주제와 노트 수, 구역을 주면 그 구역의 주제 전체', () async {
    await add('a', '개발 지식/Flutter');
    await add('b', '개발 지식/Flutter');
    await add('c', '프로젝트/세컨드브레인');
    legacyNote('옛주제', '옛 노트');
    final (code, out, _) = await brain(['topics']);
    expect(code, 0);
    expect(out, allOf(contains('개발 지식: Flutter(2)'), contains('프로젝트: 세컨드브레인(1)'), contains('공부: (없음)'), contains('옛주제(1)')));
    final (_, zone, _) = await brain(['topics', '개발 지식']);
    expect(zone, contains('Flutter'));
    expect(zone, isNot(contains('세컨드브레인')));
    final (bad, _, err) = await brain(['topics', '없는구역']);
    expect(bad, 1);
    expect(err, contains('프로젝트'));
  });

  test('brain move: 한 노트 옮기기와 되돌리기, 옛 --topic 이름으로도 찾는다', () async {
    final id = legacyNote('옛주제', '옮길 노트');
    final (code, out, err) = await brain(['move', id, '개발 지식/새주제'], env: {'BRAIN_BATCH': 'b_move-one'});
    expect(code, 0, reason: err);
    expect(out, contains('wiki/개발 지식/새주제/옮길 노트.md'));
    final (_, found, _) = await brain(['find', '옮길', '--topic', '새주제']);
    expect(found, contains(id));
    expect(found, isNot(contains('폴더에 없어')));
    final (undo, _, _) = await brain(['undo', 'b_move-one']);
    expect(undo, 0);
    expect(File(p.join(vaultRoot, 'wiki', '옛주제', '옮길 노트.md')).existsSync(), isTrue);
  });

  test('brain move --plan은 바꾸지 않고, --apply-plan은 AI 대화에서 거절, 사람이 부르면 한 묶음으로 옮긴다', () async {
    legacyNote('세컨드브레인 개발', 'Isolate.run에 클로저를 넘기면 unsendable 오류', tags: ['Flutter']);
    legacyNote('세컨드브레인 개발', 'Flutter builder에서 Navigator가 없다', tags: ['flutter']);
    legacyNote('세컨드브레인 개발', '세컨드 브레인 화면 설계 결정', tags: ['UI']);
    legacyNote('맥 관리', '디스크 정리 순서');
    final (code, plan, _) = await brain(['move', '--plan']);
    expect(code, 0);
    expect(plan, allOf(contains('개발 지식/Flutter'), contains('프로젝트/세컨드브레인'), contains('생활·기기/맥 관리')));
    expect(File(p.join(vaultRoot, 'wiki', '맥 관리', '디스크 정리 순서.md')).existsSync(), isTrue);
    final (refused, _, err) = await brain(['move', '--apply-plan'], env: ai);
    expect(refused, 1);
    expect(err, contains('폴더 정리'));
    final (applied, out, err2) = await brain(['move', '--apply-plan']);
    expect(applied, 0, reason: err2);
    expect(out, contains('옮김 4개'));
    expect(err2, contains('4/4')); // 진행 표시
    final (_, topics, _) = await brain(['topics']);
    expect(topics, allOf(contains('Flutter(2)'), contains('세컨드브레인(1)'), contains('맥 관리(1)')));
    expect(Directory(p.join(vaultRoot, 'wiki', '세컨드브레인 개발')).existsSync(), isFalse);
  });

  test('이전 방식(BRAIN_LEGACY=folders)은 예전처럼 wiki/<주제>/<제목>.md, --topic 없이도 저장', () async {
    final (code, out, _) = await add('예전 방식 노트: 긴 제목', '결제', env: {...ai, 'BRAIN_LEGACY': 'folders'});
    expect(code, 0);
    expect(out, contains('wiki/결제/예전 방식 노트- 긴 제목.md'));
    expect((await add('주제 없는 예전 노트', null, env: {...ai, 'BRAIN_LEGACY': 'folders'})).$1, 0);
  });

  test('세션 시작 안내: 저장 형식이 구역/주제와 brain topics를 알린다 (늘어난 글자 수를 잰다)', () async {
    await add('플러터 노트', '개발 지식/Flutter');
    Future<String> start(String legacy) async {
      final (_, out, _) = await brain(['hook', 'session-start'], stdin: jsonEncode({'cwd': '/tmp'}), env: {'BRAIN_LEGACY': legacy});
      return (jsonDecode(out) as Map)['hookSpecificOutput']['additionalContext'] as String;
    }

    final now = await start('');
    final before = await start('folders');
    expect(now, allOf(contains('--topic "구역/주제"'), contains('brain topics')));
    expect(before, isNot(contains('brain topics')));
    print('[토큰] 세션 시작 ${before.length}자 → ${now.length}자 (+${now.length - before.length}, 설계서_프롬프트이후 5.1)');
    expect(now.length - before.length, lessThanOrEqualTo(120));
  });
}
