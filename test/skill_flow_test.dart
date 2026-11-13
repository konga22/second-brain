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

  // 새 주제는 그 구역의 주제 전체를 본 뒤에만 만든다 (설계서_프롬프트이후 5.1-4, 11/13 검토): `brain add`가 AI 대화에서
  // 없는 주제면 멈추고(3) `--new-topic`을 받는다. AI에게 저장을 시키는 모든 곳이 이 흐름을 알아야 한다.
  for (final name in ['brain-save', 'brain-ingest']) {
    test('$name: 저장 전 brain topics로 주제 전체를 보고, 없는 주제로 멈추면(3) 맞는 주제로 바꾸거나 --new-topic', () {
      final text = skill(name);
      expect(text, allOf(contains('brain topics'), contains('--new-topic')));
    });
  }

  test('지식 폴더 AGENTS.md 안내도 --new-topic을 알린다', () {
    final text = File('packages/brain_core/lib/src/vault/vault.dart').readAsStringSync();
    expect(text, contains('--new-topic'));
  });

  // (설계서_프롬프트이후 11/13 추가: 선호 → 실수 노트) 같은 선호가 프로젝트마다 노트로 저장돼 다른 프로젝트에서 안 붙었다.
  // 프로젝트 이름을 빼도 맞는 선호·작업 규칙은 노트가 아니라 검증 에이전트로 넘겨 실수 노트로 만든다.
  test('brain-save·brain-ingest: 일반 선호·작업 규칙은 노트로 저장하지 않고 brain-verifier에 넘긴다', () {
    final save = skill('brain-save');
    expect(save, isNot(contains('- 사용자 선호·작업 규칙 ("앞으로 ~할 때는 ~한다")\n')));
    expect(save, allOf(contains('사용자 선호·작업 규칙 → 실수 노트'), contains('프로젝트 이름을 빼도 맞'), contains('brain-verifier')));
    expect(save, contains('한반도감 홈은 한지 느낌')); // 프로젝트에만 맞는 선호는 노트로 남는다
    expect(skill('brain-ingest'), contains('brain-verifier'));
    expect(skill('brain-lint'), contains('규칙 후보'));
  });

  test('설정 화면 자동 저장 설명도 선호·작업 규칙은 노트가 아니라 실수 노트 후보로 넘긴다고 말한다', () {
    final text = File('lib/features/settings/settings_page.dart').readAsStringSync();
    expect(text, isNot(contains('결정·문제 해결·작업 규칙 같은 지식')));
    expect(text, contains('선호·작업 규칙은 실수 노트 후보로'));
  });

  test('brain-verifier: 대화에서 나온 선호도 받고, 같은 규칙이면 --recorrected, 사용자 말이 없으면 승인 대기', () {
    final text = File('integrations/claude-code/agents/brain-verifier.md').readAsStringSync();
    final section = text.split('## A-2.').last.split('## B.').first;
    expect(section, contains('brain lesson evidence <id> --recorrected'));
    expect(section, contains('--status pending'));
    expect(section, contains('--quote'));
    expect(text.split('\n').firstWhere((l) => l.startsWith('description:')), contains('선호'));
  });

  // (설계서_프롬프트이후 5.4) 프로젝트 문맥은 사용자가 진행을 확인했을 때만 두 절을 고치고, 등록·경로는 사용자가 한다.
  test('second-brain·brain-save: 프로젝트 문맥은 확인된 진행만 brain project set --state/--next로, 경로는 사용자', () {
    final find = skill('second-brain');
    expect(find, allOf(contains('사용자가 진행을 확인했을 때만'), contains('brain project set --state'), contains('--next -')));
    expect(find, contains('등록·경로(`--path`)는 사용자만'));
    expect(skill('brain-save'), contains('brain project set --state'));
  });

  test('brain-save: 지난 세션을 정리하며 옛 노트를 고치면 brain write에 --source-session을 붙인다', () {
    final text = skill('brain-save');
    expect(RegExp(r'brain write <id> --expect-hash <해시> --source-session').hasMatch(text), isTrue);
  });

  // (설계서_프롬프트이후 6.3 토큰 줄이기, 11/14) 드문 경우의 자세한 설명은 `brain`이 그 자리에서 내는 안내에 맡기고
  // 스킬에는 한 줄만 둔다. 줄이다가 길을 통째로 지우지 않았는지 — 저장을 시키는 스킬이 꼭 알려야 하는 것.
  test('brain-save: 줄인 뒤에도 저장 흐름의 길이 다 남아 있다', () {
    final text = skill('brain-save');
    for (final must in [
      'brain find --drafts', // 저장 전 겹침 확인 (초안 포함)
      'brain topics', // 주제 전체를 보고 고른다
      '종료 코드 3', // brain이 멈추면 나온 안내대로
      '--new-topic',
      '--new`',
      '금지어', // 사용자가 정한 금지어는 돌려 써서 저장하지 않는다
      'brain write <id> --expect-hash', // 바뀐 결정은 옛 노트를 고친다
      'brain sessions show', // 지난 세션 정리
      '--status skipped',
      'brain undo s_',
      '--attach', // 사진
      '비밀값이 보이는 사진은 붙이지 않',
      'brain todo suggest',
      '세컨드 브레인에 저장: n_0042', // 답 끝 한 줄
      '5개까지',
      '저장하지 마',
    ]) {
      expect(text, contains(must), reason: must);
    }
  });

  // 스킬이 `brain`의 안내에 맡긴 것은 `brain`이 실제로 그 안내를 내야 한다 (실수 노트 L-0010: 같은 규칙을 모든 경로에).
  // 멈춤 안내(--new-topic, --new)는 folder_zones_cli_test·board_review_cli_test가 실제 실행으로 본다. 여기서는 문구가 남아 있는지.
  test('스킬이 맡긴 안내를 brain이 낸다: 없는 주제·비슷한 노트 멈춤, 세션 이어 읽기, 사진 거절', () {
    final add = File('packages/brain_cli/lib/src/commands/note_commands.dart').readAsStringSync();
    expect(add, allOf(contains('같은 명령에 --new-topic 을 붙여 다시 저장한다'), contains('같은 명령에 --new 를 붙여 다시 저장한다')));
    expect(add, contains('제목·요약까지 고친다'));
    final sessions = File('packages/brain_cli/lib/src/commands/sessions_command.dart').readAsStringSync();
    expect(sessions, allOf(contains('이어 보기: brain sessions show'), contains('아직 안 읽은 곳'), contains('지난번에 일부만 정리했다')));
    final assets = File('packages/brain_core/lib/src/note/note_assets.dart').readAsStringSync();
    expect(assets, allOf(contains('사진만 붙일 수 있습니다'), contains('파일이 없습니다')));
  });

  // 글자 수 예산: AI가 스킬을 부를 때마다 본문 전체가 맥락에 들어가 그 뒤 모든 턴에 다시 읽힌다 (한국어 1자 ≈ 1토큰, 토큰분석 1절).
  // 11/13~14 기능을 넣으며 brain-save가 3,455 → 6,944자로 늘었다가 11/14에 줄였다. 다시 불어나면 여기서 걸린다.
  test('스킬·에이전트 글자 수가 예산 안이다', () {
    final sizes = {
      'brain-save': (skill('brain-save').length, 4000),
      'second-brain': (skill('second-brain').length, 2500),
      'brain-ingest': (skill('brain-ingest').length, 2000),
      'brain-lint': (skill('brain-lint').length, 1600),
      'brain-verifier': (File('integrations/claude-code/agents/brain-verifier.md').readAsStringSync().length, 3500),
    };
    for (final MapEntry(key: name, value: (size, budget)) in sizes.entries) {
      expect(size, lessThanOrEqualTo(budget), reason: '$name $size자 (예산 $budget자)');
    }
    // 설명(description)은 스킬을 부르지 않아도 세션마다 목록으로 들어간다. 11/14 값(줄 머리 `description: ` 포함 1,127자)보다
    // 늘지 않게 한다. 설명은 이번에 줄이지 않았다: 스킬을 읽지 않는 경로가 줄이기 전과 글자 하나까지 같아야 견줄 수 있다.
    final descriptions = [
      for (final name in ['second-brain', 'brain-save', 'brain-ingest', 'brain-lint']) skill(name),
      File('integrations/claude-code/agents/brain-verifier.md').readAsStringSync(),
    ].map((t) => t.split('\n').firstWhere((l) => l.startsWith('description:')).length).reduce((a, b) => a + b);
    expect(descriptions, lessThanOrEqualTo(1130), reason: '설명 합계 $descriptions자');
  });
}
