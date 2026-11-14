import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 놓친 교정 줍기 (설계서_프롬프트이후 5.10 ①, 11/14): 사용자 말 + 바로 앞 AI 답 끝, 훑은 곳 기록.
void main() {
  late Directory temp;
  late ClaudeSessions sessions;
  late Vault vault;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('correction_scan_');
    sessions = ClaudeSessions(projectsDir: p.join(temp.path, 'projects'));
    vault = Vault(p.join(temp.path, 'SecondBrain'))..ensure();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  ClaudeSession write(List<Map<String, Object?>> turns) {
    final dir = Directory(p.join(temp.path, 'projects', '-Users-me-app'))..createSync(recursive: true);
    Map<String, Object?> base(String type) => {
      'type': type,
      'sessionId': 'abcdef12-3456',
      'cwd': '/Users/me/app',
      'timestamp': '2026-11-10T10:00:00.000Z',
    };
    final lines = [
      for (final t in turns)
        if (t['user'] != null)
          {...base('user'), 'message': {'role': 'user', 'content': t['user']}}
        else if (t['tool'] != null)
          {
            ...base('assistant'),
            'message': {
              'content': [
                {'type': 'tool_use', 'name': 'Bash'},
              ],
            },
          }
        else
          {
            ...base('assistant'),
            'message': {
              'content': [
                {'type': 'text', 'text': t['ai']},
              ],
            },
          },
    ];
    File(p.join(dir.path, 'abcdef12-3456.jsonl')).writeAsStringSync(lines.map(jsonEncode).join('\n'));
    return sessions.list(vault: vault).single;
  }

  test('사용자 말마다 바로 앞 AI 답의 끝을 짝짓고, 도구 출력은 넣지 않는다', () {
    final session = write([
      {'user': '결제 웹훅 고쳐 줘'},
      {'tool': true},
      {'ai': '${'가' * 200} 배포는 직접 아래 명령을 실행해 주세요.'},
      {'user': '너가 할 수 있잖아 그냥 너가 해'},
      {'ai': '네 했습니다.'},
      {'user': '좋아'},
    ]);
    final ex = sessions.exchanges(session);
    expect(ex.map((e) => e.user), ['결제 웹훅 고쳐 줘', '너가 할 수 있잖아 그냥 너가 해', '좋아']);
    expect(ex[0].ai, '', reason: '첫 말 앞에는 AI 답이 없다');
    expect(ex[1].ai, startsWith('…'));
    expect(ex[1].ai, endsWith('배포는 직접 아래 명령을 실행해 주세요.'));
    expect(ex[1].ai.length, 141, reason: 'AI 답은 끝 140자 + …');
    expect(ex[2].ai, '네 했습니다.');
  });

  test('긴 사용자 말은 300자에서 자르고, 비밀값은 가린다', () {
    final session = write([
      {'user': '키는 sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789 이거 써'},
      {'ai': '알겠습니다.'},
      {'user': '나' * 400},
    ]);
    final ex = sessions.exchanges(session);
    expect(ex[0].user, isNot(contains('abcdefghijklmnop')));
    expect(ex[1].user.length, 301);
  });

  test('훑은 곳은 세션마다 숫자만 적고, 줄어드는 값은 무시한다', () {
    final state = CorrectionScanState(vault);
    expect(state.load(), isEmpty);
    state.markScanned({'s1': 5, 's2': 3});
    state.markScanned({'s1': 2, 's2': 7});
    expect(state.load(), {'s1': 5, 's2': 7});
    final saved = File(p.join(vault.metaDir, 'correction_scan.json')).readAsStringSync();
    expect(saved, isNot(contains('사용자')), reason: '사용자 문장은 적지 않는다');
  });
}
