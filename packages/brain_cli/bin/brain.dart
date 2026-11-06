import 'dart:io';

import 'package:brain_cli/brain_cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runBrain(arguments);
}
