import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `brain doctor`가 원격이 붙은 git 폴더 안의 지식 폴더를 경고한다 (설계서_프롬프트이후 4.6).
/// 실제 `brain`과 `git`을 프로세스로 실행한다.
void main() {
  late Directory temp;
  late String repoRoot;
  late String vaultRoot;
  late String configPath;
  late String indexDir;
  final hasGit = _hasGit();

  setUp(() {
    temp = Directory.systemTemp.createTempSync('github_warning_cli_');
    repoRoot = p.join(temp.path, 'repo');
    vaultRoot = p.join(repoRoot, 'SecondBrain');
    final vault = Vault(vaultRoot)..ensure();
    indexDir = p.dirname(vault.indexPath);
    configPath = p.join(temp.path, 'config.json');
    File(configPath).writeAsStringSync(jsonEncode({'vault': vaultRoot}));
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
    final dir = Directory(indexDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<(int, String)> doctor() async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['run', p.join('bin', 'brain.dart'), 'doctor'],
      environment: {'BRAIN_VAULT': vaultRoot, 'BRAIN_CONFIG': configPath, 'CLAUDE_CODE_SESSION_ID': ''},
      stdoutEncoding: utf8,
    );
    return (result.exitCode, result.stdout as String);
  }

  test('원격 없는 git 폴더면 조용하고, 원격을 붙이면 경고하지만 실패로 끝내지 않는다', () async {
    Process.runSync('git', ['init', '-q'], workingDirectory: repoRoot);
    final (quietCode, quiet) = await doctor();
    expect(quietCode, 0);
    expect(quiet, isNot(contains('[주의]')));

    Process.runSync('git', ['remote', 'add', 'origin', 'https://me:ghp_abcdefghijklmnopqrstuvwxyz0123@github.com/x/y.git'],
        workingDirectory: repoRoot);
    final (code, out) = await doctor();
    expect(code, 0);
    expect(out, contains('[주의]'));
    expect(out, contains('origin'));
    expect(out, contains('github.com'));
    expect(out, isNot(contains('ghp_')));
  }, skip: hasGit ? false : 'git이 없다');
}

bool _hasGit() {
  try {
    return Process.runSync('git', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
