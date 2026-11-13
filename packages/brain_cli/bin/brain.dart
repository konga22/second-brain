import 'dart:async';
import 'dart:io';

import 'package:brain_cli/brain_cli.dart';

Future<void> main(List<String> arguments) async {
  // `brain show … | head`처럼 읽는 쪽이 먼저 닫히면 표준 출력 쓰기가 Broken pipe(EPIPE)로 실패한다.
  // 그때는 오류 덤프 대신 조용히 끝낸다 (기능검토 K-10). 다른 오류는 그대로 알린다.
  await runZonedGuarded(
    () async {
      exitCode = await runBrain(arguments);
    },
    (error, stack) {
      if (isBrokenPipe(error)) exit(0);
      stderr.writeln('brain: $error');
      exit(1);
    },
  );
}

/// 표준 출력을 받는 쪽이 닫혔는가 (EPIPE = 32).
bool isBrokenPipe(Object error) =>
    (error is FileSystemException && error.osError?.errorCode == 32) ||
    (error is SocketException && error.osError?.errorCode == 32) ||
    (error is StdoutException && error.osError?.errorCode == 32);
