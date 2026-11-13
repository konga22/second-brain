import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// M4 규칙 전달 (설계서_프롬프트이후 4.5·6.1): 적용 중 규칙 40개 폴더에서 가장 최근 10개가 세션 시작 안내에 몇 개 들어가나.
/// 이전 방식(번호 순 앞 30개)은 0/10이었다(기능검토 6-1 K-41). 실제 `brain`을 프로세스로 실행해 본다.
void main() {
  late Directory temp;
  late String vaultRoot;
  late String configPath;
  late String indexDir;

  String id(int n) => 'L-${n.toString().padLeft(4, '0')}';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('lesson_recency_');
    vaultRoot = p.join(temp.path, 'vault');
    final vault = Vault(vaultRoot)..ensure();
    indexDir = p.dirname(vault.indexPath);
    configPath = p.join(temp.path, 'config.json');
    File(configPath).writeAsStringSync(jsonEncode({'vault': vaultRoot}));
    // 규칙 40개: 번호가 클수록 나중에 만든 것 (10/01부터 하루씩). 파일을 직접 써서 만든 날짜를 정한다.
    Directory(vault.lessonsDir).createSync(recursive: true);
    final start = DateTime(2026, 10, 1);
    for (var n = 1; n <= 40; n++) {
      final day = start.add(Duration(days: n - 1)).toIso8601String().substring(0, 10);
      File(p.join(vault.lessonsDir, '${id(n)}.md')).writeAsStringSync(
        [
          '---',
          'id: ${id(n)}',
          'status: active',
          'trigger: "작업 $n번을 할 때"',
          'action: "규칙 $n번을 따른다"',
          'reason: "시험"',
          'source: explicit',
          'diff: ""',
          'tests: []',
          'created: $day',
          'evidence: { kept: 0, recorrected: 0 }',
          '---',
          '',
        ].join('\n'),
      );
    }
    SearchIndex.open(vault)
      ..sync()
      ..close();
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
    final dir = Directory(indexDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<String> brain(List<String> args, {String? stdin, String legacy = ''}) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', p.join('bin', 'brain.dart'), ...args],
      environment: {
        'BRAIN_VAULT': vaultRoot,
        'BRAIN_CONFIG': configPath,
        'CLAUDE_CODE_SESSION_ID': '',
        // 빈 값 = 모두 새 방식. 시험을 돌리는 셸의 BRAIN_LEGACY를 물려받지 않게 늘 준다.
        'BRAIN_LEGACY': legacy,
      },
    );
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    expect(code, 0, reason: await err);
    return out;
  }

  Future<String> sessionStart({String legacy = ''}) async {
    final out = await brain(
      ['hook', 'session-start'],
      stdin: jsonEncode({'cwd': '/tmp/x', 'session_id': 's1'}),
      legacy: legacy,
    );
    return jsonDecode(out)['hookSpecificOutput']['additionalContext'] as String;
  }

  /// 안내에 든 규칙 id (나온 순서대로).
  List<String> ruleIds(String text) => [
    for (final line in text.split('\n'))
      if (RegExp(r'^  - (L-\d{4}) ').firstMatch(line) case final m?) m.group(1)!,
  ];

  final recent = [for (var n = 31; n <= 40; n++) id(n)];

  test('M4: 규칙 40개에서 최근 10개 전달 — 이전 방식 0/10, 새 방식 10/10', () async {
    final legacyText = await sessionStart(legacy: AppConfig.legacyLessons);
    final newText = await sessionStart();
    final legacyIds = ruleIds(legacyText);
    final newIds = ruleIds(newText);
    final legacyHit = recent.where(legacyIds.contains).length;
    final newHit = recent.where(newIds.contains).length;
    print('[M4] 이전 방식 $legacyHit/10 (${legacyText.length}자) · 새 방식 $newHit/10 (${newText.length}자)');

    // 이전 방식은 그대로: 번호 순 앞 30개
    expect(legacyIds, [for (var n = 1; n <= 30; n++) id(n)]);
    expect(legacyHit, 0);
    // 새 방식: 최근 것부터 30개, 가장 오래된 10개가 빠진다
    expect(newHit, 10);
    expect(newIds, [for (var n = 40; n >= 11; n--) id(n)]);
    // 줄 모양·끝 줄은 그대로
    expect(newText, contains('  - L-0040 작업 40번을 할 때 → 규칙 40번을 따른다'));
    expect(newText.split('\n').last, '  (그 밖 10개는 해당 요청 때 붙는다)');
    expect(legacyText.split('\n').last, '  (그 밖 10개는 해당 요청 때 붙는다)');
    // 규칙이 안 바뀌면 세션마다 같은 글 (프롬프트 캐시)
    expect(await sessionStart(), newText);
  });

  test('오래된 규칙도 다시 교정되면 맨 위로 올라오고, 다시 교정 안 된 가장 오래된 것이 빠진다', () async {
    expect(ruleIds(await sessionStart()), isNot(contains(id(1))));
    await brain(['lesson', 'evidence', id(1), '--recorrected']);
    final ids = ruleIds(await sessionStart());
    expect(ids.first, id(1));
    expect(ids, hasLength(30));
    expect(ids.skip(1), [for (var n = 40; n >= 12; n--) id(n)]);
    // 이전 방식은 다시 교정과 상관없이 번호 순
    expect(ruleIds(await sessionStart(legacy: AppConfig.legacyLessons)), [for (var n = 1; n <= 30; n++) id(n)]);
  });
}
