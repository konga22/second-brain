import 'dart:io';

import 'package:path/path.dart' as p;

import '../vault/vault.dart';
import 'change_log.dart';

/// 변경 기록 한 줄 (타임라인용).
class ChangeEvent {
  const ChangeEvent({
    required this.at,
    required this.batch,
    required this.action,
    required this.detail,
    this.isAi = false,
    this.aiSession,
  });

  final DateTime at;
  final String batch;
  final String action;

  /// 기록 내용. 줄 끝의 AI 표시(` · AI 대화 <id>`)는 떼어 [isAi]·[aiSession]에 둔다 — 할 일 키·회고·타임라인에
  /// 대화 id가 섞이지 않게 (설계서_프롬프트이후 4.3, 11/13 검토).
  final String detail;

  /// AI 대화 안에서 부른 `brain` 명령이 남긴 줄인가 (설계서_프롬프트이후 4.3).
  final bool isAi;

  /// AI 대화 id. 표시가 없거나 id를 모르면 null.
  final String? aiSession;

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
  // 시각은 초까지라 한 초 안의 줄은 순서를 잃었다: AI가 본문을 고치고 바로 제목을 바꾸면 [되돌리기]가 앞 묶음부터
  // 되돌려 고친 본문이 남았다 (11/13 검토). 같은 시각이면 파일에 적힌 순서(뒤 줄이 나중)를 쓴다.
  final events = <(ChangeEvent, int)>[];
  for (final file in files.take(months)) {
    for (final text in file.readAsLinesSync()) {
      final m = line.firstMatch(text);
      final at = m == null ? null : DateTime.tryParse(m.group(1)!);
      if (m == null || at == null) continue;
      final raw = m.group(4) ?? '';
      final mark = aiLogMark.firstMatch(raw);
      events.add((
        ChangeEvent(
          at: at,
          batch: m.group(2) ?? '',
          action: m.group(3)!,
          detail: stripAiMark(raw),
          isAi: mark != null,
          aiSession: mark?.group(1),
        ),
        events.length,
      ));
    }
  }
  // 파일은 최근 달부터 읽으므로 같은 시각(달이 같음)끼리는 번호가 큰 줄이 나중이다.
  events.sort((a, b) {
    final byTime = b.$1.at.compareTo(a.$1.at);
    return byTime != 0 ? byTime : b.$2.compareTo(a.$2);
  });
  return [for (final (e, _) in events) e];
}
