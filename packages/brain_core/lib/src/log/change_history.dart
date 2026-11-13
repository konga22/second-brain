import 'dart:io';

import 'package:path/path.dart' as p;

import '../vault/vault.dart';

/// 변경 기록 한 줄 (타임라인용).
class ChangeEvent {
  const ChangeEvent({
    required this.at,
    required this.batch,
    required this.action,
    required this.detail,
  });

  final DateTime at;
  final String batch;
  final String action;
  final String detail;

  /// 기록에 나온 노트 id (`n_0042`, `L-0007`).
  String? get targetId =>
      RegExp(r'\b(n_\d{4,}|L-\d{4,}|T-\d{4,})\b').firstMatch(detail)?.group(1);
}

/// `_log/YYYY-MM.md`를 읽어 최신 순으로 돌려준다 (설계서 3.3 타임라인).
List<ChangeEvent> readChangeHistory(Vault vault, {int months = 3}) {
  final dir = Directory(vault.logDir);
  if (!dir.existsSync()) return const [];
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => RegExp(r'^\d{4}-\d{2}\.md$').hasMatch(p.basename(f.path)))
      .toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  final line = RegExp(r'^- (\S+) (?:\[([^\]]+)\] )?(\S+) ?(.*)$');
  final events = <ChangeEvent>[];
  for (final file in files.take(months)) {
    for (final text in file.readAsLinesSync()) {
      final m = line.firstMatch(text);
      final at = m == null ? null : DateTime.tryParse(m.group(1)!);
      if (m == null || at == null) continue;
      events.add(
        ChangeEvent(
          at: at,
          batch: m.group(2) ?? '',
          action: m.group(3)!,
          detail: m.group(4) ?? '',
        ),
      );
    }
  }
  events.sort((a, b) => b.at.compareTo(a.at));
  return events;
}
