import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 5.2 페르소나 질문 4문항 (설계서_프롬프트이후 5.2): `me.md`의 금지어가 든 노트는 `brain add`·`brain write`가 막고,
/// 세션 시작 안내에는 일·답 방식 한 줄만 더한다. 실제 `brain`을 프로세스로 실행한다 (한 번 컴파일해 쓴다).
void main() {
  late Directory temp;
  late String exe;
  late String vaultRoot;
  late String configPath;
  late String indexDir;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('persona_cli_');
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

  /// 사용자가 앱에서 적은 것과 같은 모양의 me.md.
  void writeMe() => const Persona(
    work: '대림대 3학년, 세컨드 브레인 맥 앱을 혼자 만드는 중',
    keeps: ['프로젝트 결정·구조', '개발 지식·해결법'],
    answerStyle: Persona.styleShort,
    forbidden: ['연봉', '주민등록번호', '집 주소', 'Hansol', '건강검진', '돈'],
  ).save(Vault(vaultRoot));

  List<String> noteFiles() => [
    for (final f in Directory(p.join(vaultRoot, 'wiki')).listSync(recursive: true))
      if (f is File && f.path.endsWith('.md') && p.basename(f.path) != 'index.md') f.path,
  ];

  test('측정: 금지어가 든 노트 5개는 모두 막히고, 없는 노트 5개는 하나도 막히지 않는다', () async {
    writeMe();
    // AI가 대화에서 저장할 때 쓸 만한 말투로, 금지어를 그대로 쓰지 않고 붙여 쓰기·대소문자·띄어쓰기·자모 풀어쓰기를 섞었다.
    final nfdTitle = '건강검진 예약 메모';
    final forbidden = [
      ('이직 준비 체크리스트', '올해 연봉협상 전에 정리할 것', '포트폴리오 링크를 정리한다\n면접 일정을 확인한다'),
      ('사내 VPN 접속 설정', '회사 VPN은 WireGuard로 접속한다', 'HANSOL-VPN 프로필을 받아 넣는다\n접속이 안 되면 DNS를 바꾼다'),
      ('택배 배송지 정리', '쇼핑몰마다 배송지가 달라 헷갈린다', '집주소는 새 아파트로 바꿨다\n회사 쪽 주소는 그대로'),
      (nfdTitle, '병원 예약 확인 방법', '전날 밤 9시부터 금식\n결과는 2주 뒤 문자로 온다'),
      ('은행 앱 본인인증 오류', '본인인증이 계속 실패해 고객센터에 물어봄', '주민등록번호 앞자리를 다시 넣으니 됐다\n앱 업데이트도 했다'),
    ];
    // 금지어 일부(연·주소·건강·Han)나 1글자 금지어(돈)만 든 평소 노트
    final clean = [
      ('연구실 서버 접속 방법', '연구실 서버는 학교 VPN을 거쳐 접속한다', 'ssh 포트는 2222다\n비밀번호 대신 키로 접속한다'),
      ('API 서버 주소를 env로 분리', '서버 주소는 env 파일로 뺀다', 'dev와 prod 주소가 다르다\n빌드 때 --dart-define으로 넣는다'),
      ('헬스체크 엔드포인트', '서버 건강 상태를 /health로 본다', '1분마다 건강 상태를 확인한다\n실패 3번이면 알림'),
      ('Flutter 창 크기 기억', '창 크기를 config.json에 저장한다', '돈 드는 서비스 없이 파일에 쓴다\n앱을 다시 열면 읽는다'),
      ('한글 자모 정규화', 'macOS 파일 이름은 NFD라 비교 전에 NFC로', 'Hangul 조합 규칙만 구현했다\n라틴 결합 부호는 그대로'),
    ];
    Future<bool> blocked((String, String, String) note) async {
      final (title, summary, body) = note;
      final (code, out, err) = await brain(['add', '--title', title, '--summary', summary], stdin: '$body\n');
      if (code == 0) return false;
      expect(err, contains('저장하지 않았습니다'), reason: '다른 이유로 실패하면 측정이 아니다: $out $err');
      return true;
    }

    var forbiddenBlocked = 0;
    for (final note in forbidden) {
      if (await blocked(note)) forbiddenBlocked++;
    }
    var cleanBlocked = 0;
    for (final note in clean) {
      if (await blocked(note)) cleanBlocked++;
    }
    // ignore: avoid_print
    print('5.2 금지어 노트 막힘 $forbiddenBlocked/5, 금지어 없는 노트 막힘 $cleanBlocked/5');
    expect(forbiddenBlocked, 5);
    expect(cleanBlocked, 0);
    expect(noteFiles(), hasLength(5), reason: '막힌 노트는 파일도 남지 않는다');
  });

  test('거절 글에 어느 말인지 나오고, AI 세션에서도 막힌다', () async {
    writeMe();
    final (code, _, err) = await brain(
      ['add', '--title', '사내 메신저 설정', '--summary', 'hansol 메신저 알림 끄기'],
      stdin: '설정에서 알림을 끈다\n',
      env: {'CLAUDECODE': '1'},
    );
    expect(code, isNot(0));
    expect(err, contains('"Hansol"'));
    expect(err, contains('요약'));
    expect(err, contains('사용자에게 알'));
  });

  test('brain write: 본문·요약에 금지어를 넣으면 거절하고 노트는 그대로', () async {
    writeMe();
    final (code, out, err) = await brain(['add', '--title', '면접 준비', '--summary', '자주 나온 질문 정리'], stdin: '자기소개 1분\n');
    expect(code, 0, reason: err);
    final id = RegExp(r'n_\d+').firstMatch(out)!.group(0)!;
    final (_, show, _) = await brain(['show', id]);
    final hash = RegExp(r'해시 ([0-9a-f]+)').firstMatch(show)!.group(1)!;

    final (c1, _, e1) = await brain(['write', id, '--expect-hash', hash], stdin: '자기소개 1분\n희망 연봉은 회사 내규에 따름\n');
    expect(c1, isNot(0));
    expect(e1, contains('"연봉"'));
    final (c2, _, e2) = await brain(['write', id, '--expect-hash', hash, '--summary', '집 주소 바뀐 것 알리기']);
    expect(c2, isNot(0));
    expect(e2, contains('"집 주소"'));
    final (_, after, _) = await brain(['show', id]);
    expect(after, contains('해시 $hash'), reason: '거절했으면 노트는 그대로');
    final (c3, _, e3) = await brain(['write', id, '--expect-hash', hash], stdin: '자기소개 1분\n지원 동기 30초\n');
    expect(c3, 0, reason: e3);
  });

  test('지난 세션으로 저장할 때 막히면 세션 사본도 남기지 않는다', () async {
    writeMe();
    final home = p.join(temp.path, 'case', 'home');
    final project = Directory(p.join(home, '.claude', 'projects', '-Users-me-shop'))..createSync(recursive: true);
    File(p.join(project.path, 'cafe0003-aaaa.jsonl')).writeAsStringSync(
      '${[
        for (final (i, text) in ['이직할 때 연봉 얘기 어떻게 해?', '희망 연봉은 범위로 말한다'].indexed)
          jsonEncode({
            'type': i == 0 ? 'user' : 'assistant',
            'sessionId': 'cafe0003-aaaa',
            'cwd': '/Users/me/shop',
            'timestamp': '2026-11-01T10:0$i:00.000Z',
            'message': {'role': i == 0 ? 'user' : 'assistant', 'content': text},
          }),
      ].join('\n')}\n',
    );
    final (code, _, err) = await brain(
      ['add', '--draft', '--source-session', 'cafe0003', '--title', '연봉 협상 요령', '--summary', '범위로 말한다'],
      stdin: '희망 연봉은 범위로 말한다\n',
      env: {'HOME': home},
    );
    expect(code, isNot(0));
    expect(err, contains('"연봉"'));
    final sessions = Directory(Vault(vaultRoot).rawSessionsDir);
    expect(sessions.listSync().whereType<File>(), isEmpty, reason: '거절한 저장의 대화 사본이 지식 폴더에 남으면 안 된다');
  });

  test('세션 시작 안내: 일·답 방식 한 줄만 더하고, 세션마다 같고, 금지어는 넣지 않는다', () async {
    final (code, out, err) = await brain(['add', '--title', '결제 웹훅 재시도', '--summary', '3번까지 재시도', '--topic', '결제'], stdin: '간격을 늘린다\n');
    expect(code, 0, reason: '$out $err');
    String context(String raw) =>
        (jsonDecode(raw) as Map<String, dynamic>)['hookSpecificOutput']['additionalContext'] as String;
    final input = jsonEncode({'cwd': temp.path});
    final (_, before, _) = await brain(['hook', 'session-start'], stdin: input);
    writeMe();
    final (_, first, _) = await brain(['hook', 'session-start'], stdin: input);
    final (_, second, _) = await brain(['hook', 'session-start'], stdin: input);
    final a = context(before);
    final b = context(first);
    expect(a, contains('· 주제: 결제'), reason: '_profile.md 주제 줄을 계속 읽는다');
    expect(b, contains('· 사용자: 대림대 3학년, 세컨드 브레인 맥 앱을 혼자 만드는 중 · 답 방식: 짧게 결론 먼저'));
    expect(second, first, reason: 'me.md가 그대로면 세션마다 같은 글 (캐시)');
    for (final term in ['연봉', '주민등록번호', '집 주소', 'Hansol', '건강검진', '저장하면 안']) {
      expect(b, isNot(contains(term)));
    }
    expect(b.split('\n').length, a.split('\n').length + 1, reason: '한 줄만 더한다');
    // ignore: avoid_print
    print('5.2 세션 시작 안내 ${a.length}자 → ${b.length}자 (+${b.length - a.length}자)');

    // 온보딩 요약을 끄면 이 줄도 빠진다
    File(configPath).writeAsStringSync(jsonEncode({'vault': vaultRoot, 'onboardingOff': true}));
    final (_, off, _) = await brain(['hook', 'session-start'], stdin: input);
    expect(context(off), isNot(contains('· 사용자:')));
  });
}
