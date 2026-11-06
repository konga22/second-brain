import 'dart:io';

import 'package:path/path.dart' as p;

import '../note/note.dart';
import '../vault/vault.dart';

/// 변경 기록 `_log/YYYY-MM.md`에 한 줄 추가한다 (추가만 함, 설계서 4.1).
void appendChangeLog(Vault vault, String action, String detail) {
  final now = DateTime.now();
  final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
  final file = File(p.join(vault.logDir, '$month.md'));
  file.parent.createSync(recursive: true);
  if (!file.existsSync()) file.writeAsStringSync('# 변경 기록 $month\n\n');
  file.writeAsStringSync(
    '- ${formatTime(now)} $action $detail\n',
    mode: FileMode.append,
    flush: true,
  );
}
