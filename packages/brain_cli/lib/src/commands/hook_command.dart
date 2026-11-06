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
  String get description => '훅 전용: session-start, session-end';

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
