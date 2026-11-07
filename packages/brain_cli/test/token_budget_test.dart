import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 토큰 예산 시험 (2026-11-07, docs/토큰분석.md): 세컨드 브레인이 사용자 AI 맥락에 넣는 글자 수가
/// 예산을 넘지 않는지 본다. 돈이 드는 실제 측정 없이 매번 돌릴 수 있다.
///
/// 한국어는 실제 측정에서 1글자 ≈ 1토큰이었다 (세션 시작 안내 661자 → 677토큰, claude -p usage 차이).
/// 예산은 "지금 값보다 나빠지지 않게"가 기준이고, 설계서 목표는 주석에 적는다.
void main() {
  late Directory temp;
  late String vaultRoot;
  late String configPath;
  late String indexDir;

  setUpAll(() {
    temp = Directory.systemTemp.createTempSync('token_budget_');
    vaultRoot = p.join(temp.path, 'vault');
    final vault = Vault(vaultRoot)..ensure();
    final index = SearchIndex.open(vault);
    indexDir = p.dirname(vault.indexPath);
    final notes = NoteStore(vault, index);
    // 실제 지식 폴더와 비슷한 크기: 주제 5개, 노트 30개, 실수 노트 5개.
    for (var i = 0; i < 30; i++) {
      notes.add(
        title: '결제 웹훅 재시도 규칙 $i',
        summary: '웹훅 실패 시 3번까지 간격을 늘려 재시도한다 (사례 $i)',
        body: '결제 웹훅이 실패하면 1분·5분·30분 간격으로 3번까지 다시 보낸다.\n\n- 이유: 결제사 서버 일시 장애가 대부분 30분 안에 풀렸다.\n',
        topic: ['결제', '배포', '검색', '아이폰', '맥 관리'][i % 5],
      );
    }
    final lessons = LessonStore(vault, index);
    for (var i = 0; i < 5; i++) {
      lessons.add(
        trigger: '커밋하거나 push할 때 $i',
        action: '매번 사용자에게 명시적으로 허락을 받는다',
        reason: '사용자 규칙',
        status: LessonStatus.active,
      );
    }
    VaultSummary(vault, index).writeAll();
    index.close();
    configPath = p.join(temp.path, 'config.json');
    File(configPath).writeAsStringSync(jsonEncode({'vault': vaultRoot}));
  });

  tearDownAll(() {
    temp.deleteSync(recursive: true);
    // 시험용 지식 폴더의 색인(~/Library/Caches/…/<해시>)도 지운다.
    Directory(indexDir).deleteSync(recursive: true);
  });

  /// brain 명령을 실제로 실행하고 표준 출력을 돌려준다.
  Future<String> brain(List<String> args, {String? stdin}) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', p.join('bin', 'brain.dart'), ...args],
      environment: {
        'BRAIN_VAULT': vaultRoot,
        'BRAIN_CONFIG': configPath,
      },
    );
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final out = await process.stdout.transform(utf8.decoder).join();
    await process.exitCode;
    return out;
  }

  String context(String hookOutput) => hookOutput.trim().isEmpty
      ? ''
      : (jsonDecode(hookOutput)['hookSpecificOutput']['additionalContext'] as String);

  Future<String> prompt(String text) async => context(
    await brain(['hook', 'prompt'], stdin: jsonEncode({'prompt': text, 'cwd': '/tmp/x', 'session_id': 's1'})),
  );

  test('세션 시작 안내: 700자 이하 (설계서 목표 150토큰 — 줄이기 전)', () async {
    final text = context(
      await brain(['hook', 'session-start'], stdin: jsonEncode({'cwd': '/tmp/x', 'session_id': 's1'})),
    );
    print('[토큰] 세션 시작 ${text.length}자');
    expect(text.length, lessThanOrEqualTo(700));
  });

  test(
    '세션 시작 안내가 세션마다 같다 (다르면 Claude Code가 지난 세션 캐시를 못 써 세션마다 약 1.35만 토큰을 다시 씀)',
    () async {
      Future<String> start(String id) async => context(
        await brain(['hook', 'session-start'], stdin: jsonEncode({'cwd': '/tmp/x', 'session_id': id})),
      );
      expect(await start('aaaa'), await start('bbbb'));
    },
    skip: '최적화 P1 적용 전: 안내에 세션 id가 들어 있다 (docs/토큰분석.md)',
  );

  test('관계없는 요청은 0자 (설계서 5.1)', () async {
    expect(await prompt('안녕'), isEmpty);
    expect(await prompt('오늘 날씨 어때'), isEmpty);
  });

  test('실수 노트가 맞는 요청: 3줄·400자 이하', () async {
    final text = await prompt('커밋하고 push 해 줘');
    print('[토큰] 실수 노트 안내 ${text.length}자');
    expect(text, isNotEmpty);
    expect(text.split('\n').where((l) => l.startsWith('- L-')).length, lessThanOrEqualTo(3));
    expect(text.length, lessThanOrEqualTo(400));
  });

  test('만들기 요청: 안내 + 관련 노트 3개, 500자 이하', () async {
    final text = await prompt('결제 웹훅 재시도 기능 만들어 줘');
    print('[토큰] 만들기 요청 안내 ${text.length}자');
    expect(text.length, lessThanOrEqualTo(500));
  });

  test('질문에 확실히 맞는 노트를 미리 넣는다 (R2): 최대 3개, 400자 이하', () async {
    final text = await prompt('결제 웹훅 재시도 간격이 어떻게 돼?');
    print('[토큰] 미리 넣기 ${text.length}자');
    expect(text, contains('세컨드 브레인에 이 요청과 맞는 노트가 있다'));
    expect(text.split('\n').where((l) => l.startsWith('- n_')).length, inInclusiveRange(1, 3));
    expect(text.length, lessThanOrEqualTo(400));
  });

  test('답 없는 찾기는 "확실한 노트 없음" 한 줄 (R1: 약한 후보를 근거로 쓰지 않게)', () async {
    // '결제'만 맞고 나머지 단어는 어느 노트에도 없다 → 약한 후보만 있으니 숨긴다.
    final weak = await brain(['find', '결제 투자 전략']);
    expect(weak.trim().split('\n'), hasLength(1));
    expect(weak, startsWith('확실한 노트 없음'));
    // 조각 하나도 안 맞으면 원래대로 "찾은 노트 없음".
    final none = await brain(['find', '주식 배당']);
    expect(none.trim().split('\n'), hasLength(1));
  });

  test('brain find: 5줄·1,000자 이하', () async {
    final out = await brain(['find', '결제 웹훅 재시도']);
    print('[토큰] find ${out.length}자');
    expect(out.trim().split('\n').length, lessThanOrEqualTo(5));
    expect(out.length, lessThanOrEqualTo(1000));
  });
}
