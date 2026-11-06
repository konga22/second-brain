import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('세션 기록에서 대화 문장만 추리고 도구는 한 줄로 줄인다', () {
    final temp = Directory.systemTemp.createTempSync('sessions_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final project = Directory(p.join(temp.path, 'projects', '-Users-me-app'))
      ..createSync(recursive: true);
    Map<String, Object?> base(String type) => {
      'type': type,
      'sessionId': 'abcdef12-3456',
      'cwd': '/Users/me/app',
      'gitBranch': 'main',
      'timestamp': '2026-11-05T10:00:00.000Z',
    };
    final records = [
      {
        ...base('user'),
        'message': {'role': 'user', 'content': '결제 웹훅 재시도는 어떻게 해?'},
      },
      {
        ...base('assistant'),
        'message': {
          'content': [
            {'type': 'tool_use', 'name': 'Bash'},
            {'type': 'tool_use', 'name': 'Read'},
          ],
        },
      },
      {
        ...base('user'),
        'message': {
          'content': [
            {'type': 'tool_result', 'content': '긴 출력'},
          ],
        },
      },
      {
        ...base('assistant'),
        'message': {
          'content': [
            {'type': 'thinking', 'thinking': '...'},
            {'type': 'text', 'text': '3번까지 재시도해요.'},
          ],
        },
      },
      {
        ...base('user'),
        'isMeta': true,
        'message': {'content': '메타'},
      },
      {
        ...base('user'),
        'message': {'content': '<command-name>/model</command-name>'},
      },
      {
        ...base('user'),
        'isSidechain': true,
        'message': {'content': '보조 에이전트'},
      },
      {
        ...base('user'),
        'message': {'content': '좋아 키는 OPENAI_API_KEY=abcd1234efgh 야'},
      },
    ];
    File(p.join(project.path, 'abcdef12-3456.jsonl'))
        .writeAsStringSync(records.map(jsonEncode).join('\n'));

    final sessions = ClaudeSessions(projectsDir: p.join(temp.path, 'projects'));
    final vault = Vault(p.join(temp.path, 'SecondBrain'));
    final session = sessions.list(vault: vault).single;
    expect(session.userCount, 2);
    expect(session.aiCount, 1);
    expect(session.toolCount, 2);
    expect(session.project, 'app');
    expect(session.title, '결제 웹훅 재시도는 어떻게 해?');

    final text = sessions.condense(session);
    expect(text, contains('[사용자] 결제 웹훅 재시도는 어떻게 해?'));
    expect(text, contains('(도구 2개 실행)'));
    expect(text, contains('[AI] 3번까지 재시도해요.'));
    expect(text, contains('OPENAI_API_KEY=[가림]'));
    expect(text, isNot(contains('긴 출력')));
    expect(text, isNot(contains('보조 에이전트')));

    // 지식 폴더 안에서 돈 세션은 뺀다.
    expect(sessions.list(vault: Vault('/Users/me')), isEmpty);
  });
}
