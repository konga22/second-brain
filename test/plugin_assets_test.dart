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
}
