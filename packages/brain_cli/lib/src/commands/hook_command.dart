import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:brain_core/brain_core.dart';

import '../brain_context.dart';

/// `brain hook <이벤트>`: Claude Code 훅 전용 (표준 입력 JSON).
///
/// 훅은 실패해도 사용자 작업을 막지 않게 항상 0으로 끝낸다.
class HookCommand extends Command<int> {
  HookCommand(this.context);

  final BrainContext context;

  @override
  String get name => 'hook';

  @override
  String get description => '훅 전용: session-start, prompt, session-end';

  @override
  Future<int> run() async {
    final event = argResults!.rest.isEmpty ? '' : argResults!.rest.first;
    Map<String, dynamic> input = {};
    try {
      final raw = await readStdin();
      if (raw != null && raw.trim().isNotEmpty) {
        input = jsonDecode(raw) as Map<String, dynamic>;
      }
    } on FormatException {
      input = {};
    }
    try {
      switch (event) {
        case 'session-start':
          _sessionStart(input);
        case 'prompt':
          _prompt(input);
        case 'session-end':
          _sessionEnd(input);
      }
    } on Object catch (e) {
      stderr.writeln('brain hook $event: $e');
    }
    return 0;
  }

  /// 세션 시작: 온보딩 요약(`_profile.md`)과, 대화 중 자동 저장이 켜져 있으면 그 안내 한 줄.
  /// 둘 다 꺼져 있으면 아무것도 넣지 않는다 (0토큰). 지식 폴더 안 세션(정리용 실행)은 빼고.
  void _sessionStart(Map<String, dynamic> input) {
    final config = AppConfig.load();
    final cwd = input['cwd'] as String? ?? '';
    final sessionId = input['session_id'] as String?;
    final parts = <String>[];
    if (!config.isOnboardingOff) {
      final profile = File(context.vault.profilePath);
      if (profile.existsSync()) {
        final text = clip(profile.readAsStringSync(), 600);
        if (text.isNotEmpty) {
          parts.add('사용자의 세컨드 브레인 요약 (brain find로 더 찾을 수 있음): $text');
        }
      }
    }
    if (!config.isAutoCaptureOff &&
        sessionId != null &&
        !(cwd.isNotEmpty && context.vault.contains(cwd))) {
      parts.add(autoCaptureNote(sessionId));
    }
    if (parts.isEmpty) return;
    stdout.write(
      jsonEncode({
        'hookSpecificOutput': {
          'hookEventName': 'SessionStart',
          'additionalContext': parts.join('\n'),
        },
      }),
    );
  }

  /// 대화 중 자동 저장 안내 (설계서 5.6 "대화 중 자동 저장", 2026-11-07 사용자 요청).
  static String autoCaptureNote(String sessionId) =>
      '세컨드 브레인 자동 저장이 켜져 있다. 이 대화에서 오래 쓸 지식(결정과 이유, 문제→원인→해결, 사용자 선호·작업 규칙, 자주 쓸 설정·명령, 쓸 만한 도구·레포·참고 자료)이 '
      '확정되면 사용자에게 묻지 말고 그때 brain-save 스킬 규칙대로 초안으로 저장하고, 답 끝에 "세컨드 브레인에 저장: <id> <제목> (초안)" 한 줄만 덧붙인다. '
      '세션 id는 $sessionId 이다(brain add --source-session). 잡담·추측·한 번 쓰고 마는 내용·비밀값은 저장하지 않고, 같은 지식은 brain find로 확인해 다시 넣지 않는다. 한 세션에 많아도 5개.';

  static final _systemInput = RegExp(r'<task-notification>|\[SYSTEM NOTIFICATION|^\s*<system-reminder|\[Subagent hand-back\]|<agent-message ');

  // 만들기 요청: "만들어 줘", "구현해", "똑같이", "클론", "추가해 줘", "개발해" 등.
  static final _buildIntent = RegExp(
    r'(만들(어|고 ?싶|자|기|려)|구현|개발(해|하자|하고)|추가해|똑같이|따라 ?만들|클론|복제해|짜 ?줘|붙여 ?줘|도입하|clone|build|implement)',
    caseSensitive: false,
  );

  /// 요청과 관련된 노트 최대 3개. 요청의 단어 머리가 제목·요약·태그에 2개 이상 들어 있어야
  /// 후보로 본다 (단어 하나만 맞는 약한 후보로 토큰을 쓰지 않게).
  static List<IndexedDoc> relatedNotes(SearchIndex index, String prompt) {
    index.sync();
    final heads = LessonStore.wordHeads(prompt)
        .where((h) => !_buildWords.contains(h))
        .toList();
    if (heads.isEmpty) return const [];
    final out = <IndexedDoc>[];
    for (final doc in index.search(prompt, limit: 8)) {
      final text = toNfc('${doc.title} ${doc.summary} ${doc.tags}').toLowerCase();
      final matched = heads.where(text.contains).length;
      if (matched >= 2 || heads.length == 1 && matched == 1) out.add(doc);
      if (out.length >= 3) break;
    }
    return out;
  }

  /// 만들기 요청에 흔한 말은 관련 판단에서 뺀다.
  static const _buildWords = {'만들', '구현', '개발', '추가', '똑같', '해줘', '싶어', '어떻', '어떤', '이거', '그거', '기능'};

  // 교정 신호: 사용자가 바로 앞 답을 고치는 말. 기기에서 단어 규칙으로만 1차 감지한다 (설계서 5.4).
  static final _correction = RegExp(
    r'^\s*(아니(야|요|라|지)?(?=[\s.,!?]|$)|아닌데|틀렸|틀린|잘못|다시\s*해|그게\s*아니|그렇게\s*말고|하지\s*말라|하지\s*말랬|왜\s.*(안|말)|no[,.! ]|wrong|that.s not)',
    caseSensitive: false,
  );

  /// UserPromptSubmit: 맞는 실수 노트가 있을 때만 최대 3줄, 교정 신호면 한 줄 안내.
  /// 둘 다 없으면 아무것도 쓰지 않는다 (0토큰, 설계서 5.1).
  void _prompt(Map<String, dynamic> input) {
    final prompt = '${input['prompt'] ?? ''}';
    if (prompt.trim().isEmpty) return;
    // 백그라운드 작업 알림 같은 시스템 입력은 사용자 요청이 아니라 건너뛴다 (사용기 #13).
    if (_systemInput.hasMatch(prompt)) return;
    final cwd = input['cwd'] as String? ?? '';
    final lines = <String>[
      for (final lesson in context.lessons.match(prompt))
        '- ${lesson.id} ${lesson.line} (이유: ${clip(lesson.reason, 40)})',
    ];
    final isCorrection = _correction.hasMatch(prompt) && !context.vault.contains(cwd);
    // 만들기·구현 요청이면 관련 지식을 먼저 검토하고 도입을 제안하게 한다 (11/07 사용자 요청).
    final isBuild = _buildIntent.hasMatch(prompt) && !context.vault.contains(cwd);
    final related = isBuild ? relatedNotes(context.index, prompt) : const <IndexedDoc>[];
    if (lines.isEmpty && !isCorrection && !isBuild) return;
    final text = [
      if (lines.isNotEmpty) ...['사용자의 실수 노트 (이번 요청에 적용):', ...lines],
      if (isBuild) ...[
        '만들기 요청이다. 시작 전에 second-brain 스킬대로 세컨드 브레인에서 관련 지식(비슷한 시도·쓸 만한 도구·레포·결정)을 '
            '다른 표현으로도 2~3번 찾고, 쓸 만한 게 있으면 먼저 "세컨드 브레인에 ○○가 있다 → 도입하면 장점 / 안 하면 예상 결과 / 추천"으로 제안한 뒤 진행한다.',
        if (related.isNotEmpty) '관련 지식 후보:',
        for (final doc in related) '- ${doc.id} ${doc.title} — ${clip(doc.summary, 50)}',
      ],
      if (isCorrection)
        '사용자가 앞 답을 고치는 것 같다면, 고친 내용을 반영하고 일반 규칙이 될 만하면 '
            'brain-verifier 에이전트에 질문·답·반응·diff를 넘겨 실수 노트 후보를 확인한다.',
    ].join('\n');
    stdout.write(
      jsonEncode({
        'hookSpecificOutput': {
          'hookEventName': 'UserPromptSubmit',
          'additionalContext': text,
        },
      }),
    );
  }

  /// 세션 id만 "저장 안 한 세션"으로 적는다. 지식 폴더 안 세션은 뺀다.
  void _sessionEnd(Map<String, dynamic> input) {
    final id = input['session_id'] as String?;
    final cwd = input['cwd'] as String? ?? '';
    if (id == null || (cwd.isNotEmpty && context.vault.contains(cwd))) return;
    final current = context.registry.load()[id];
    if (current?.isDone ?? false) return;
    context.registry.mark(
      id,
      SessionStatus.unsaved,
      transcriptPath: input['transcript_path'] as String?,
    );
  }
}
