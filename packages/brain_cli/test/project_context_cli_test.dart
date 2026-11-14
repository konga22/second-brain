import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 프로젝트 문맥 (설계서_프롬프트이후 5.4). 실제 `brain`을 프로세스로 실행한다.
///
/// - `brain project set --path <폴더> --name <이름>`: 사람이 `wiki/프로젝트/<이름>/_project.md`를 만들고 고친다.
///   AI 대화 안에서는 "지금 상태"·"다음 할 일"(`--state`·`--next`)만 고칠 수 있다 — 등록·경로 바꾸기는 거절.
/// - 세션 시작 훅: 작업 폴더가 프로젝트 경로 아래면 평소 안내 뒤에 두 절만 붙인다. 밖이면 한 글자도 같다 (세션 캐시).
void main() {
  late Directory temp;
  late String exe;
  late String home;
  late String vaultRoot;
  late String configPath;
  late String work;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('project_cli_');
    final out = p.join(temp.path, 'build');
    final result = await Process.run(Platform.resolvedExecutable, ['build', 'cli', '-o', out]);
    if (result.exitCode != 0) fail('brain 빌드 실패: ${result.stderr}');
    exe = p.join(out, 'bundle', 'bin', 'brain');
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  setUp(() {
    final dir = Directory(p.join(temp.path, 'case'))..createSync();
    // HOME을 바꿔 색인 위치를 시험 폴더 안으로 둔다 (진짜 지식 폴더·캐시를 건드리지 않게).
    home = p.join(dir.path, 'home');
    Directory(home).createSync();
    vaultRoot = p.join(dir.path, 'vault');
    Vault(vaultRoot).ensure();
    configPath = p.join(dir.path, 'config.json');
    File(configPath).writeAsStringSync(jsonEncode({'vault': vaultRoot}));
    work = p.join(dir.path, 'work', 'shop');
    Directory(p.join(work, 'app', 'lib')).createSync(recursive: true);
  });

  tearDown(() => Directory(p.join(temp.path, 'case')).deleteSync(recursive: true));

  const ai = {'CLAUDECODE': '1', 'CLAUDE_CODE_SESSION_ID': 'aaaa1111-2222'};

  Future<(int, String, String)> brain(List<String> args, {String? stdin, Map<String, String> env = const {}, String? cwd}) async {
    final process = await Process.start(exe, args, workingDirectory: cwd, environment: {
      'HOME': home,
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

  String pagePath(String name) => p.join(vaultRoot, 'wiki', '프로젝트', name, '_project.md');

  String contextOf(String out) => (jsonDecode(out) as Map)['hookSpecificOutput']['additionalContext'] as String;

  Future<String> sessionStart(String cwd, {String source = 'startup'}) async {
    final (code, out, err) = await brain(['hook', 'session-start'], stdin: jsonEncode({'cwd': cwd, 'session_id': 's1', 'source': source}));
    expect(code, 0, reason: err);
    return out;
  }

  /// 평소 안내가 비지 않게 실수 노트 하나를 둔다.
  void seedLesson() {
    final vault = Vault(vaultRoot);
    final index = SearchIndex.open(vault, path: p.join(temp.path, 'case', 'seed.db'));
    try {
      LessonStore(vault, index).add(trigger: '커밋할 때', action: '사용자에게 허락을 받는다', reason: '사용자 규칙', status: LessonStatus.active);
    } finally {
      index.close();
    }
  }

  test('사람: set --path --name으로 만들고, --state·--next(- 는 표준 입력)로 두 절을 쓴다, show로 본다', () async {
    var (code, out, err) = await brain(['project', 'set', '--path', work, '--name', '쇼핑몰']);
    expect(code, 0, reason: err);
    expect(out, contains('wiki/프로젝트/쇼핑몰/_project.md'));
    expect(File(pagePath('쇼핑몰')).readAsStringSync(), allOf(contains('- 경로: $work'), contains('## 지금 상태'), contains('## 다음 할 일')));
    (code, out, err) = await brain(['project', 'set', '--name', '쇼핑몰', '--state', '결제 붙이는 중', '--next', '-'], stdin: '- 환불 화면\n- 배포\n');
    expect(code, 0, reason: err);
    (code, out, err) = await brain(['project', 'show'], cwd: p.join(work, 'app'));
    expect(code, 0, reason: err);
    expect(out, allOf(contains('쇼핑몰'), contains('결제 붙이는 중'), contains('- 환불 화면')));
    // 이름 없이 지금 폴더로 찾아 고친다
    (code, out, err) = await brain(['project', 'set', '--state', '결제 끝남'], cwd: work);
    expect(code, 0, reason: err);
    expect(File(pagePath('쇼핑몰')).readAsStringSync(), allOf(contains('결제 끝남'), contains('- 배포')));
    // 이상한 입력은 1, 페이지를 만들지 않는다
    (code, _, err) = await brain(['project', 'set', '--path', p.join(work, 'none'), '--name', '없는 폴더']);
    expect(code, 1);
    expect(err, contains('없는 폴더'));
    (code, _, err) = await brain(['project', 'set', '--name', '이름만']);
    expect(code, 1);
    (code, _, err) = await brain(['project', 'set', '--state', 'x'], cwd: temp.path);
    expect(code, 1);
    expect(Directory(p.join(vaultRoot, 'wiki', '프로젝트')).listSync().map((e) => p.basename(e.path)), ['쇼핑몰']);
  });

  test('AI 대화: 등록·경로 바꾸기는 거절하고, 지금 폴더 프로젝트의 두 절만 --state·--next로 고친다', () async {
    var (code, _, err) = await brain(['project', 'set', '--path', work, '--name', '쇼핑몰'], env: ai);
    expect(code, 1);
    expect(err, contains('사용자'));
    expect(File(pagePath('쇼핑몰')).existsSync(), isFalse);
    await brain(['project', 'set', '--path', work, '--name', '쇼핑몰']);
    final file = File(pagePath('쇼핑몰'));
    file.writeAsStringSync('${file.readAsStringSync()}\n## 메모\n\n사용자 메모\n');
    (code, _, err) = await brain(['project', 'set', '--next', '- 환불 화면'], env: ai, cwd: p.join(work, 'app'));
    expect(code, 0, reason: err);
    (code, _, err) = await brain(['project', 'set'], env: ai, cwd: work); // 고칠 절 없음
    expect(code, 1);
    (code, _, err) = await brain(['project', 'set', '--name', '쇼핑몰', '--path', temp.path, '--state', 'x'], env: ai);
    expect(code, 1);
    final text = file.readAsStringSync();
    expect(text, allOf(contains('- 환불 화면'), contains('사용자 메모'), isNot(contains('- 경로: ${temp.path}\n'))));
    // 변경 기록에 AI 표시가 남아 되돌릴 수 있다
    final log = Directory(p.join(vaultRoot, '_log')).listSync().whereType<File>().map((f) => f.readAsStringSync()).join();
    expect(log, contains('project wiki/프로젝트/쇼핑몰/_project.md (다음 할 일) · AI 대화 aaaa1111-2222'));
  });

  test('세션 시작: 프로젝트 밖·두 절이 빈 프로젝트는 한 글자도 같고, 안이면 평소 안내 뒤에 두 절만 붙는다 (가장 긴 경로)', () async {
    seedLesson();
    final before = await sessionStart(work);
    expect(before, isNotEmpty);
    await brain(['project', 'set', '--path', work, '--name', '쇼핑몰']);
    expect(await sessionStart(p.join(work, 'app')), before, reason: '두 절이 비면 0자');
    await brain(['project', 'set', '--name', '쇼핑몰', '--state', '결제 붙이는 중', '--next', '- 환불 화면']);
    final outside = p.join(temp.path, 'case', 'work', 'other');
    Directory(outside).createSync();
    expect(await sessionStart(outside), before);
    expect(await sessionStart('${work}2'), before); // 앞부분만 같은 다른 폴더

    final base = contextOf(before);
    final inside = contextOf(await sessionStart(p.join(work, 'app', 'lib')));
    expect(inside, startsWith('$base\n'));
    final extra = inside.substring(base.length + 1);
    print('[프로젝트 문맥] 세션 시작에 붙는 글 ${extra.length}자:\n$extra');
    expect(extra, allOf(contains('"쇼핑몰"'), contains('데이터'), contains('결제 붙이는 중'), contains('- 환불 화면')));
    expect(extra, isNot(contains(work)));

    // 안쪽 폴더를 따로 등록하면 그쪽이 이긴다
    await brain(['project', 'set', '--path', p.join(work, 'app'), '--name', '쇼핑몰 앱', '--state', '앱 화면 작업']);
    final nested = contextOf(await sessionStart(p.join(work, 'app', 'lib')));
    expect(nested, allOf(contains('앱 화면 작업'), isNot(contains('결제 붙이는 중'))));

    // 압축 직후에도 같은 자리, 압축 줄은 그 뒤에
    final compact = contextOf(await sessionStart(p.join(work, 'app', 'lib'), source: 'compact'));
    expect(compact, startsWith(nested));
    // 지식 폴더 안 세션(정리용 실행)은 예전처럼 아무것도 넣지 않는다
    expect(await sessionStart(vaultRoot), isEmpty);
  });

  test('세션 시작: 안내가 모두 꺼져 있어도(실수 노트도 없음) 프로젝트 안이면 두 절만 넣는다, 페이지가 깨져도 0으로 끝난다', () async {
    File(configPath).writeAsStringSync(jsonEncode({'vault': vaultRoot, 'onboardingOff': true, 'autoCaptureOff': true}));
    expect(await sessionStart(work), isEmpty);
    await brain(['project', 'set', '--path', work, '--name', '쇼핑몰', '--next', '배포']);
    expect(contextOf(await sessionStart(work)), contains('배포'));
    File(pagePath('쇼핑몰')).writeAsBytesSync([0xff, 0xfe, 0x00, 0x41]);
    final (code, _, _) = await brain(['hook', 'session-start'], stdin: jsonEncode({'cwd': work}));
    expect(code, 0);
  });

  test('노트 1만 개 지식 폴더에서 프로젝트 안 세션 시작 훅 시간 (프로세스 시작 포함)', () async {
    seedLesson();
    // 노트 파일을 바로 쓰고 색인을 한 번 만든다 (NoteStore.add를 1만 번 부르는 것보다 빠르다)
    final zones = ['프로젝트/쇼핑몰', '프로젝트/한반도감', '개발 지식/결제', '개발 지식/배포', '생활·기기/맥 관리'];
    for (var i = 0; i < 10000; i++) {
      final id = 'n_${(i + 1).toString().padLeft(5, '0')}';
      final file = File(p.join(vaultRoot, 'wiki', zones[i % zones.length], '노트 $i.md'));
      if (i < zones.length) file.parent.createSync(recursive: true);
      file.writeAsStringSync('---\nid: $id\ntitle: "노트 $i"\nsummary: "요약 $i"\ntags: []\naliases: []\nsource: manual\nsources: []\nstatus: active\n---\n\n본문 $i\n');
    }
    for (var i = 0; i < 20; i++) {
      final dir = Directory(p.join(temp.path, 'case', 'work', 'p$i'))..createSync(recursive: true);
      await brain(['project', 'set', '--path', dir.path, '--name', '프로젝트 $i', '--state', '상태 $i', '--next', '할 일 $i']);
    }
    await brain(['project', 'set', '--path', work, '--name', '쇼핑몰', '--state', '결제 붙이는 중', '--next', '- 환불 화면']);
    final (indexCode, _, indexErr) = await brain(['index']);
    expect(indexCode, 0, reason: indexErr);
    await sessionStart(work); // 첫 실행(색인 확인)은 빼고 잰다
    Future<int> time(String cwd) async {
      final runs = <int>[];
      for (var i = 0; i < 5; i++) {
        final watch = Stopwatch()..start();
        await sessionStart(cwd);
        runs.add(watch.elapsedMilliseconds);
      }
      runs.sort();
      return runs[2];
    }

    final inside = await time(p.join(work, 'app'));
    final outside = await time(temp.path);
    print('[프로젝트 문맥] 노트 1만 개·프로젝트 21개: 프로젝트 안 ${inside}ms / 밖 ${outside}ms (중앙값, 프로세스 시작 포함)');
    expect(contextOf(await sessionStart(work)), contains('결제 붙이는 중'));
    expect(inside, lessThan(1000)); // 느린 기계·병렬 시험에서도 넉넉히. 실제 값은 위 출력
  });
}
