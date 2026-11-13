import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 스킬 흐름이 `brain add`의 비슷한 노트 멈춤(설계서_프롬프트이후 4.4, 종료 코드 3)과 어긋나지 않는지 (11/13 검토).
///
/// 예전 brain-save 3절은 보완할 내용을 `보완: <원래 제목>` 초안으로 저장하라고 했다. 원래 노트와 핵심 단어가 거의 같아
/// AI 대화에서는 거의 늘 멈췄고(3), 화면 없는 정리에서 AI가 옛 노트만 고치면 세션 표시가 남지 않았다.
void main() {
  String skill(String name) => File('integrations/claude-code/skills/$name/SKILL.md').readAsStringSync();

  for (final name in ['brain-save', 'brain-ingest']) {
    test('$name: "보완:" 초안을 만들지 않고, 더할 사실은 --new 초안으로 저장한다', () {
      final text = skill(name);
      expect(text, isNot(contains('보완: <원래 제목>')));
      expect(text, contains('--new'));
    });
  }

  test('brain-save: 지난 세션을 정리하며 옛 노트를 고치면 brain write에 --source-session을 붙인다', () {
    final text = skill('brain-save');
    expect(RegExp(r'brain write <id> --expect-hash <해시> --source-session').hasMatch(text), isTrue);
  });
}
