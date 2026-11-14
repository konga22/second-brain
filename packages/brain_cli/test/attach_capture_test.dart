import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 5.5 캡처 첨부 (설계서_프롬프트이후 5.5): `brain add --attach <사진>`.
/// 끝난 기준: 사진 1장 → assets/에 1개, 같은 사진을 다른 노트에 다시 붙이면 그대로 1개, 본문이 링크한다.
/// 실제 `brain`을 프로세스로 실행한다 (draft_separation_test와 같은 방식).
void main() {
  late Directory temp;
  late String exe;
  late String vaultRoot;
  late String configPath;
  late String indexDir;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('attach_capture_');
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
      // 이 시험을 Claude Code 안에서 돌려도 바깥 세션이 물려오지 않게
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

  /// PNG 머리 + 채운 바이트.
  String png(String name, {int size = 4096, int seed = 1}) {
    final bytes = Uint8List(size);
    for (var i = 0; i < size; i++) {
      bytes[i] = (i * 17 + seed) & 0xff;
    }
    bytes.setRange(0, 8, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    final file = File(p.join(temp.path, 'case', 'in', name))..createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file.path;
  }

  List<File> assets() {
    final dir = Directory(p.join(vaultRoot, 'assets'));
    return dir.existsSync() ? dir.listSync().whereType<File>().toList() : [];
  }

  String noteText(String rel) => File(p.join(vaultRoot, rel)).readAsStringSync();

  /// "n_0001 저장함 ...  wiki/주제/제목.md" 에서 경로.
  String savedPath(String out) => RegExp(r'(wiki/.+\.md)$', multiLine: true).firstMatch(out)!.group(1)!;

  test('끝난 기준: 1장 → assets/ 1개, 같은 사진을 다른 노트에 → 그대로 1개, 두 본문이 링크한다', () async {
    final shot = png('스크린샷 2026-11-13 오후 3.12.45.png');
    final (code1, out1, err1) = await brain(
      ['add', '--title', '서명 오류 화면', '--summary', 'Xcode 서명 오류 캡처', '--topic', '개발 지식/Flutter', '--attach', shot],
      stdin: 'Xcode 서명 오류가 났다.\n',
    );
    expect(code1, 0, reason: err1);
    expect(out1, contains('사진 1장'));
    expect(assets(), hasLength(1));
    final name = p.basename(assets().single.path);
    final first = noteText(savedPath(out1));
    // 구역/주제 아래라 한 단계 더 깊다 (설계서_프롬프트이후 5.1)
    expect(first, contains('](../../../assets/$name)'));

    final (code2, out2, err2) = await brain(
      ['add', '--title', '같은 캡처 다른 노트', '--summary', '같은 사진', '--topic', '개발 지식/배포', '--attach', shot],
      stdin: '같은 사진을 다시 붙였다.\n',
    );
    expect(code2, 0, reason: err2);
    expect(assets(), hasLength(1), reason: '같은 사진은 한 번만 저장한다');
    expect(noteText(savedPath(out2)), contains('](../../../assets/$name)'));
  });

  test('--attach 여러 번: 2장 붙임', () async {
    final (code, out, err) = await brain(
      ['add', '--title', '두 장', '--summary', '요약', '--attach', png('a.png'), '--attach', png('b.png', seed: 7)],
      stdin: '본문\n',
    );
    expect(code, 0, reason: err);
    expect(out, contains('사진 2장'));
    expect(assets(), hasLength(2));
  });

  test('사진이 아니면 한국어로 거절하고 노트도 남기지 않는다', () async {
    final text = File(p.join(temp.path, 'case', 'in', '메모.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('글');
    final (code, out, err) = await brain(
      ['add', '--title', '거절', '--summary', '요약', '--attach', text.path],
      stdin: '본문\n',
    );
    expect(code, 1);
    expect(err, contains('사진만 붙일 수 있습니다'));
    expect(out, isNot(contains('저장함')));
    expect(assets(), isEmpty);
    expect(Directory(p.join(vaultRoot, 'wiki')).listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test('AI 세션에서 붙여 저장해도 초안이다 (4.1 그대로)', () async {
    final (code, out, err) = await brain(
      ['add', '--title', 'AI 캡처', '--summary', '요약', '--topic', '개발 지식/캡처', '--attach', png('a.png')],
      stdin: '본문\n',
      env: {'CLAUDECODE': '1'},
    );
    expect(code, 0, reason: err);
    expect(noteText(savedPath(out)), contains('status: draft'));
    expect(assets(), hasLength(1));
  });

  test('brain undo로 되돌리면 노트와 새 사진이 함께 휴지통으로 간다', () async {
    final (code, _, err) = await brain(
      ['add', '--title', '되돌릴 캡처', '--summary', '요약', '--attach', png('a.png')],
      stdin: '본문\n',
      env: {'BRAIN_BATCH': 'b_attach'},
    );
    expect(code, 0, reason: err);
    final (undoCode, _, undoErr) = await brain(['undo', 'b_attach']);
    expect(undoCode, 0, reason: undoErr);
    expect(assets(), isEmpty);
  });
}
