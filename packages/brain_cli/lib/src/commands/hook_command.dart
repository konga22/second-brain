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
          _sessionStart();
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

  /// 온보딩 요약(`_profile.md`)이 있을 때만 짧게 넣는다. 없으면 0토큰.
  void _sessionStart() {
    if (AppConfig.load().isOnboardingOff) return; // 설정에서 끔
    final profile = File(context.vault.profilePath);
    if (!profile.existsSync()) return;
    final text = clip(profile.readAsStringSync(), 600);
    if (text.isEmpty) return;
    stdout.write(
      jsonEncode({
        'hookSpecificOutput': {
          'hookEventName': 'SessionStart',
          'additionalContext': '사용자의 세컨드 브레인 요약 (brain find로 더 찾을 수 있음): $text',
        },
      }),
    );
  }

  static final _systemInput = RegExp(r'<task-notification>|^\s*\[SYSTEM NOTIFICATION|^\s*<system-reminder');

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
    if (lines.isEmpty && !isCorrection) return;
    final text = [
      if (lines.isNotEmpty) ...['사용자의 실수 노트 (이번 요청에 적용):', ...lines],
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
