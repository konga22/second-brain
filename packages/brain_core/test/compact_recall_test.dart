import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 압축 뒤 되살리기 (설계서_프롬프트이후 11/13 추가: 압축 훅).
///
/// 압축하면 사용자가 한 지시가 요약 속에서 뭉개진다. SessionStart(source=compact) 때 세션 기록 끝에서 사용자가 직접 친
/// 말만 원문으로 최근 것부터 4,000자까지 다시 넣는다(11/13 압축 훅: 2,000자는 끝에서 2,239자 앞 지시를 놓쳤다). "지시처럼 보이는가"로 고르지 않는다(분류하지 않기로 함).
void main() {
  late Directory temp;
  late String projects;
  late String transcript;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('compact_recall_');
    projects = p.join(temp.path, 'projects');
    final dir = Directory(p.join(projects, '-Users-me-app'))..createSync(recursive: true);
    transcript = p.join(dir.path, 'abcdef12-3456.jsonl');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Map<String, Object?> user(Object content, {Map<String, Object?> extra = const {}, bool human = true}) => {
    'type': 'user',
    'sessionId': 'abcdef12-3456',
    if (human) 'origin': {'kind': 'human'},
    if (human) 'promptSource': 'sdk',
    'message': {'role': 'user', 'content': content},
    ...extra,
  };

  Map<String, Object?> ai(String text) => {
    'type': 'assistant',
    'message': {
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  };

  void write(List<Map<String, Object?>> records) =>
      File(transcript).writeAsStringSync('${records.map(jsonEncode).join('\n')}\n');

  List<String>? recall({int maxChars = CompactRecall.maxChars, bool Function(String)? drop, String? path}) =>
      CompactRecall.recentUserMessages(path ?? transcript, projectsDir: projects, maxChars: maxChars, drop: drop);

  test('사용자가 친 말만 오래된 것부터: 도구 결과·메타·곁가지·압축 요약·명령·작업 알림·에이전트 보고·자동 메시지는 뺀다', () {
    write([
      user('커밋은 허락받고 해'),
      ai('알겠습니다.'),
      user([
        {'type': 'tool_result', 'tool_use_id': 't1', 'content': '도구 출력: 사용자 말처럼 보이는 글'},
      ], extra: {'toolUseResult': {'stdout': 'x'}}, human: false),
      user([
        {'type': 'text', 'text': 'Base directory for this skill: /x\n# 스킬 본문'},
      ], extra: {'isMeta': true}, human: false),
      user('곁가지 에이전트에게 준 일', extra: {'isSidechain': true}),
      user('This session is being continued from a previous conversation.', extra: {'isCompactSummary': true, 'isVisibleInTranscriptOnly': true}, human: false),
      user('<command-name>/model</command-name>\n<command-args>opus</command-args>', human: false),
      user('<task-notification>\n<task-id>a1</task-id>\n</task-notification>', extra: {'origin': {'kind': 'task-notification'}, 'promptSource': 'system'}, human: false),
      user('Another Claude session sent a message: <agent-message from="a"> [Subagent hand-back] 보고서', extra: {'origin': {'kind': 'peer'}, 'promptSource': 'system', 'isMeta': true}, human: false),
      user('<system-reminder>\nThe session "x" finished\n</system-reminder>', extra: {'promptSource': 'sdk'}, human: false),
      user('I hit my usage limit while you were working, but it has reset now. Please continue from where you left off.', extra: {'promptSource': 'sdk'}, human: false),
      user([
        {'type': 'text', 'text': '[Request interrupted by user]'},
      ], human: false),
      user([
        {'type': 'text', 'text': '<system-reminder>\n세션 알림\n</system-reminder>'},
        {'type': 'text', 'text': '교수님 프롬프트는 문서로만 남겨'},
      ]),
      ai('네.'),
      user('이름표 자르지 마'),
    ]);
    expect(recall(), ['커밋은 허락받고 해', '교수님 프롬프트는 문서로만 남겨', '이름표 자르지 마']);
  });

  test('최근 것부터 4,000자까지 담고 순서는 오래된 것부터, 넘치면 거기서 멈춘다', () {
    final old = '오래된 말 ${'가' * 2500}';
    final middle = '가운데 말 ${'나' * 1800}';
    final newest = '마지막 말 ${'다' * 1800}';
    write([user(old), ai('a'), user(middle), ai('b'), user(newest)]);
    final got = recall()!;
    expect(got, [middle, newest]);
    expect(got.fold<int>(0, (n, t) => n + t.runes.length), lessThanOrEqualTo(4000));
  });

  test('끝에서 2,239자 앞에 있던 지시도 담는다 (11/13 압축 훅: 실제 기록에서 2,000자일 때 놓친 모양)', () {
    const key = '교수님 프롬프트는 문서로만 남겨';
    final middle = '가운데 말 ${'나' * 1200}';
    final newest = '마지막 말 ${'다' * 1000}';
    write([user('오래된 말 ${'가' * 2000}'), user(key), ai('a'), user(middle), ai('b'), user(newest)]);
    expect(recall(), [key, middle, newest]);
  });

  test('마지막 말 하나가 4,000자를 넘으면 앞부분만 잘라 담는다', () {
    write([user('짧은 말'), user('긴 말 ${'라' * 9000}')]);
    final got = recall()!;
    expect(got, hasLength(1));
    expect(got.single, startsWith('긴 말 라'));
    expect(got.single.runes.length, 4000);
    expect(got.single, endsWith('…'));
  });

  test('비밀값은 가리고, drop이 참인 말(실수 노트와 같은 말)은 빼고 그 앞 말을 더 담는다', () {
    write([
      user('키는 sk-ant-abcdefghijklmnop0123456789 이거 써'),
      user('결제 코드 고칠 때 테스트 키로 먼저 해'),
      user('이제 화면 고쳐'),
    ]);
    final got = recall(drop: (t) => t.contains('테스트 키로 먼저'))!;
    expect(got, ['키는 [가림] 이거 써', '이제 화면 고쳐']);
  });

  test('세션 기록 폴더 밖·링크·폴더·없는 파일·.jsonl 아닌 파일은 읽지 않는다 (null)', () {
    write([user('안쪽 말')]);
    final outside = File(p.join(temp.path, 'outside.jsonl'))..writeAsStringSync('${jsonEncode(user('바깥 말'))}\n');
    final link = Link(p.join(projects, '-Users-me-app', 'link.jsonl'))..createSync(outside.path);
    final notJsonl = File(p.join(projects, '-Users-me-app', 'a.txt'))..writeAsStringSync('${jsonEncode(user('글'))}\n');
    expect(recall(), ['안쪽 말']);
    expect(recall(path: outside.path), isNull);
    expect(recall(path: link.path), isNull);
    expect(recall(path: p.join(projects, '-Users-me-app')), isNull);
    expect(recall(path: p.join(projects, 'none.jsonl')), isNull);
    expect(recall(path: notJsonl.path), isNull);
    expect(recall(path: p.join(projects, '..', 'outside.jsonl')), isNull);
    expect(recall(path: ''), isNull);
  });

  test('깨진 줄·잘린 마지막 줄이 있어도 멈추지 않는다', () {
    File(transcript).writeAsStringSync(
      '${jsonEncode(user('첫 말'))}\n{"type":"user", 깨짐\n${jsonEncode(user('둘째 말'))}\n{"type":"user","message":{"content":"잘',
    );
    expect(recall(), ['첫 말', '둘째 말']);
  });

  test('50MB 기록: 끝에서만 읽어 200ms 안 (도구 출력이 큰 실제 기록 모양)', () {
    final sink = File(transcript).openSync(mode: FileMode.write);
    final bigTool = jsonEncode(user([
      {'type': 'tool_result', 'tool_use_id': 't', 'content': 'x' * 200000},
    ], extra: {'toolUseResult': {'stdout': 'y'}}, human: false));
    var size = 0;
    var n = 0;
    while (size < 50 * 1024 * 1024) {
      final line = n % 20 == 0 ? jsonEncode(user('지시 $n번')) : bigTool;
      sink.writeStringSync('$line\n');
      size += line.length + 1;
      n++;
    }
    sink.closeSync();
    final watch = Stopwatch()..start();
    final got = recall()!;
    watch.stop();
    // ignore: avoid_print
    print('압축 뒤 되살리기: ${(File(transcript).lengthSync() / 1024 / 1024).toStringAsFixed(1)}MB에서 ${got.length}개, ${watch.elapsedMilliseconds}ms');
    expect(got, isNotEmpty);
    expect(got.last, startsWith('지시 '));
    expect(watch.elapsedMilliseconds, lessThan(200));
  });
}
