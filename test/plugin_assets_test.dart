import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 앱의 [연동]이 복사하는 파일이 앱 자산에 다 들어 있는지 (bash tool/build_brain.sh 뒤).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('플러그인 원본과 brain 실행 파일이 앱 자산에 있다', () async {
    for (final path in [
      'integrations/claude-code/marketplace.json',
      'integrations/claude-code/plugin.json',
      'integrations/claude-code/hooks.json',
      'integrations/claude-code/skills/second-brain/SKILL.md',
      'integrations/claude-code/skills/brain-save/SKILL.md',
      'integrations/claude-code/skills/brain-ingest/SKILL.md',
      'integrations/claude-code/skills/brain-lint/SKILL.md',
      'integrations/claude-code/agents/brain-verifier.md',
    ]) {
      expect(await rootBundle.loadString(path), isNotEmpty, reason: path);
    }
    final brain = await rootBundle.load('assets/brain/bin/brain');
    final sqlite = await rootBundle.load('assets/brain/lib/libsqlite3.dylib');
    expect(brain.lengthInBytes, greaterThan(1000000));
    expect(sqlite.lengthInBytes, greaterThan(1000000));
  });

  // 11/11: 앱에 11/08 판 brain이 묶여 [연동]이 플러그인을 옛 판으로 내렸다 (기능검토 K-22).
  // 크기만 보던 위 시험은 옛 판이어도 통과했다. 어떤 소스로 빌드했는지를 견준다 (설계서 v1.3.27).
  test('앱 자산의 brain이 지금 CLI·코어 소스로 빌드한 것이다', () {
    const fix = 'bash tool/build_brain.sh 를 실행한 뒤 다시 빌드하세요 (정식 빌드는 bash tool/release.sh).';
    final recorded = File('assets/brain/SOURCE_HASH');
    expect(recorded.existsSync(), isTrue, reason: 'assets/brain/SOURCE_HASH가 없습니다. $fix');
    final now = Process.runSync('bash', ['tool/brain_source_hash.sh']);
    expect(now.exitCode, 0, reason: '소스 해시를 계산하지 못했습니다: ${now.stderr}');
    expect(
      recorded.readAsStringSync().trim(),
      (now.stdout as String).trim(),
      reason: 'assets/brain의 brain이 옛 판입니다(소스가 바뀐 뒤 다시 빌드하지 않음). $fix',
    );
  });
}
