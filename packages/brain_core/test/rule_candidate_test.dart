import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 규칙 후보 점검 (설계서_프롬프트이후 11/13 추가: 선호 → 실수 노트).
///
/// 같은 사용자 선호("AI 티 나는 디자인은 쓰지 않는다")가 프로젝트마다 따로 노트로 저장됐다. 노트는 요청 단어가
/// 맞을 때만 붙고 실수 노트는 세션마다 붙으므로, 정리된 노트 중 일반 선호·작업 규칙처럼 보이는 것을 "규칙 후보"로
/// 알린다. AI 없이 단어 규칙만 쓰고, 자동으로 바꾸지 않는다.
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('rule_candidate_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index, zoned: false);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  // 일반 선호·작업 규칙: 사용자 메모리·피드백에 실제로 있는 것을 AI가 저장할 법한 제목으로.
  const general = [
    'AI 티 나는 디자인은 쓰지 않는다',
    '사용자는 보라색 그라데이션·이모지 많은 화면을 싫어한다',
    '답변은 항상 한국어로, 코드·경로만 원문',
    '커밋은 사용자가 허락할 때만 한다',
    '스크린샷은 요청할 때만 찍어 보낸다',
    '선택지를 물을 때는 쉬운 말과 예를 넣는다',
    '교수님 메일과 작업 보고는 회사식으로 쓴다',
    '한반도감 디자인: 뻔한 AI 스타일 싫어함',
    '김민상 작업 규칙 (커밋·PR·보고)',
    '찾은 자료를 프로젝트와 연결 짓기 전에 먼저 묻는다',
  ];

  // 프로젝트 결정·기술 지식: 실제 지식 폴더 제목과 스킬 예시. '규칙'·'마다'·'안 함'처럼 헷갈리는 말을 일부러 넣었다.
  const other = [
    '한반도감 홈은 한지 느낌으로 간다',
    '한반도감 홈 디자인 결정: 기존 홈 다듬기 + 아래 B(카드 하나 + 탭)',
    '한반도감 API 잔액 약 50달러 — 프로젝트 API 가급적 사용 안 함',
    '시험 프로세스는 CLAUDE_CODE_SESSION_ID를 비우고 띄운다',
    'SQLite 여러 프로세스 동시 열기: busy_timeout을 WAL 설정보다 먼저',
    '결제 웹훅 재시도 규칙',
    '주간 회의 결정: 배포 요일',
    '세컨드 브레인 화면 설계 결정 (시안 v8)',
    'Flutter macOS 통합 시험은 파일마다 따로 돌린다',
    '앱에서 claude -p 화면 없이 실행하는 규칙',
  ];

  test('측정: 일반 선호 제목 10개 중 9개 이상, 프로젝트·기술 제목 10개 중 0개를 규칙 후보로 본다', () {
    final hit = [for (final t in general) if (Linter.ruleCandidateHint(title: t) != null) t];
    final falseHit = [for (final t in other) if (Linter.ruleCandidateHint(title: t) != null) t];
    // ignore: avoid_print
    print('규칙 후보 측정: 일반 선호 ${hit.length}/10, 프로젝트·기술 ${falseHit.length}/10 '
        '(놓침: ${general.where((t) => !hit.contains(t)).join(' / ')}; 헛걸림: ${falseHit.join(' / ')})');
    expect(hit.length, greaterThanOrEqualTo(9));
    expect(falseHit, isEmpty);
  });

  test('태그가 선호·작업 규칙이면 제목이 평범해도 후보다', () {
    expect(Linter.ruleCandidateHint(title: '디자인 메모', tags: '선호, 디자인'), isNotNull);
    expect(Linter.ruleCandidateHint(title: '디자인 메모', tags: '작업규칙'), isNotNull);
    expect(Linter.ruleCandidateHint(title: '디자인 메모', tags: '디자인, 결제'), isNull);
  });

  // 실제 지식 폴더 사본에서 헛걸린 요약 (11/13): 기술 조건의 "때만/때는"은 규칙이 아니다.
  test('"~때만/때는"은 제목에서만 보고, 요약의 기술 조건은 후보가 아니다', () {
    expect(Linter.ruleCandidateHint(title: 'Mac에서 iPhone 전체 백업과 Manifest.db 생성', summary: 'Manifest.db는 Finder 전체 백업 때만 생기고 ExFAT 외장엔 못 쓴다'), isNull);
    expect(Linter.ruleCandidateHint(title: '앱 밖에서 저장한 노트가 앱에 안 뜨던 문제', summary: 'CLI가 색인을 먼저 맞춰 앱 확인이 0개 → 폴더 감시 때는 무조건 다시 그림'), isNull);
    expect(Linter.ruleCandidateHint(title: '커밋은 사용자가 허락할 때만 한다'), '때만');
  });

  test('brain lint: 정리된 노트만 규칙 후보로 알리고, 초안·실수 노트는 건드리지 않는다', () {
    final (rule, rulePath) = store.add(
      title: '앞으로 화면은 AI 티 나는 디자인을 쓰지 않는다',
      summary: '보라색 그라데이션·이모지 남발 금지',
      body: '사용자가 여러 프로젝트에서 같은 말을 했다.',
      tags: ['디자인'],
      topic: '한반도감',
    );
    final (draft, _) = store.add(
      title: '보고서는 항상 회사식으로 쓴다',
      summary: '서명은 김민상 올림',
      body: '초안이다.',
      draft: true,
    );
    final (project, _) = store.add(
      title: '한반도감 홈은 한지 느낌으로 간다',
      summary: '홈 배경과 카드에 한지 질감',
      body: '11/10 피드백.',
      topic: '한반도감',
    );
    final before = File(p.join(vault.root, rulePath)).readAsStringSync();
    final candidates = [
      for (final i in Linter(vault, index).run())
        if (i.type == LintType.ruleCandidate) i,
    ];
    expect(candidates.map((i) => i.id), [rule]);
    expect(candidates.single.message, contains('실수 노트'));
    expect(candidates.single.canFix, isFalse);
    expect(candidates.map((i) => i.id), isNot(contains(draft)));
    expect(candidates.map((i) => i.id), isNot(contains(project)));
    // 자동으로 바꾸지 않는다: 노트는 그대로, 실수 노트는 0개
    expect(File(p.join(vault.root, rulePath)).readAsStringSync(), before);
    expect(LessonStore(vault, index).all(), isEmpty);
  });
}
