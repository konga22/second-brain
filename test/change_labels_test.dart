import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secondbrain/shared/change_labels.dart';

/// 변경 기록 작업 이름이 화면에 날것("topic-add 22")으로 보이지 않게: brain_core가 쓰는 작업 이름을 소스에서 모아
/// 모두 화면 글이 있는지 본다 (11/13 화면 검토).
void main() {
  test('brain_core가 변경 기록에 쓰는 작업 이름은 모두 화면 글이 있다', () {
    final written = <String>{};
    final literal = RegExp(r"'([a-z]+(?:-[a-z]+)*)'");
    for (final file in Directory('packages/brain_core/lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final src = file.readAsStringSync();
      // appendChangeLog(vault, 'add', … / appendChangeLog(\n vault,\n isRenamed ? 'rename' : 'update', …: 두 번째 인자의 글자들
      for (final m in RegExp(r'appendChangeLog\(\s*vault,\s*([^,]+),').allMatches(src)) {
        written.addAll(literal.allMatches(m.group(1)!).map((x) => x.group(1)!));
      }
      // 실수 노트 저장(action: 'lesson-…')과 할 일 고치기(_editLine(…, 'todo-…'))는 변수로 넘긴다
      written.addAll(RegExp(r"action: '([a-z-]+)'").allMatches(src).map((x) => x.group(1)!));
      written.addAll(RegExp(r"'(todo-[a-z]+)'").allMatches(src).map((x) => x.group(1)!));
    }
    expect(written, containsAll(['add', 'topic-add', 'move', 'lesson-merge', 'attach', 'todo-done']), reason: '시험 전제: 소스에서 찾았다');
    expect(written.where((a) => !changeActionLabels.containsKey(a)), isEmpty);
    expect(changeActionLabel('topic-add'), '주제 만듦');
  });
}
