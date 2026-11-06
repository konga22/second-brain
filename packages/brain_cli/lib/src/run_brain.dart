import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:brain_core/brain_core.dart';

/// brain 명령을 실행하고 종료 코드를 돌려준다.
Future<int> runBrain(List<String> arguments) async {
  final runner = CommandRunner<int>('brain', '세컨드 브레인 지식 폴더 명령')
    ..addCommand(_DoctorCommand());
  try {
    return await runner.run(arguments) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    return 64;
  }
}

/// 지금은 SQLite 기능만 점검한다. 지식 폴더·색인 점검은 3주차에 붙인다.
class _DoctorCommand extends Command<int> {
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
    return support.isReady ? 0 : 1;
  }
}
