import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:brain_core/brain_core.dart';

import 'brain_context.dart';
import 'commands/check_commands.dart';
import 'commands/hook_command.dart';
import 'commands/lesson_commands.dart';
import 'commands/note_commands.dart';
import 'commands/sessions_command.dart';
import 'commands/todo_command.dart';

/// brain 명령을 실행하고 종료 코드를 돌려준다 (설계서 5.1).
Future<int> runBrain(List<String> arguments) async {
  final context = BrainContext();
  final runner =
      CommandRunner<int>(
          'brain',
          '세컨드 브레인 지식 폴더 명령 (지식 폴더: ${context.vault.root})',
        )
        ..addCommand(FindCommand(context))
        ..addCommand(ShowCommand(context))
        ..addCommand(AddCommand(context))
        ..addCommand(WriteCommand(context))
        ..addCommand(SessionsCommand(context))
        ..addCommand(HookCommand(context))
        ..addCommand(IndexCommand(context))
        ..addCommand(LessonCommand(context))
        ..addCommand(UndoCommand(context))
        ..addCommand(TodoCommand(context))
        ..addCommand(LintCommand(context))
        ..addCommand(BenchCommand(context))
        ..addCommand(_DoctorCommand(context));
  // `brain sessions [옵션]`은 `brain sessions list [옵션]`과 같다.
  final args = [...arguments];
  if (args.isNotEmpty &&
      args.first == 'sessions' &&
      (args.length == 1 ||
          args[1].startsWith('-') && args[1] != '-h' && args[1] != '--help')) {
    args.insert(1, 'list');
  }
  // `brain lesson <상황>`은 `brain lesson find <상황>`과 같다.
  if (args.length >= 2 &&
      args.first == 'lesson' &&
      !args[1].startsWith('-') &&
      !LessonCommand.subcommandNames.contains(args[1])) {
    args.insert(1, 'find');
  }
  try {
    return await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    return 64;
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    return 64;
  } finally {
    context.close();
  }
}

class _DoctorCommand extends Command<int> {
  _DoctorCommand(this.context);

  final BrainContext context;

  @override
  String get name => 'doctor';

  @override
  String get description => '실행 환경을 점검한다.';

  @override
  int run() {
    final support = checkSqliteSupport();
    stdout.writeln('SQLite ${support.version}');
    for (final (label, ok) in support.items) {
      stdout.writeln('${ok ? '[통과]' : '[실패]'} $label');
    }
    if (support.error != null) stdout.writeln('오류: ${support.error}');
    final vaultExists = Directory(context.vault.root).existsSync();
    stdout.writeln(
      '${vaultExists ? '[통과]' : '[없음]'} 지식 폴더 ${context.vault.root}',
    );
    var indexOk = false;
    if (vaultExists) {
      final result = context.index.sync();
      indexOk = true;
      stdout.writeln(
        '[통과] 색인 ${context.vault.indexPath} (노트 ${context.index.notes().length}개, 이번 갱신 $result)',
      );
    }
    final sessionsDir = Directory(context.sessions.projectsDir).existsSync();
    stdout.writeln(
      '${sessionsDir ? '[통과]' : '[없음]'} Claude Code 세션 기록 ${context.sessions.projectsDir}',
    );
    return support.isReady && (!vaultExists || indexOk) ? 0 : 1;
  }
}
