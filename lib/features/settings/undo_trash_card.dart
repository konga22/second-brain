import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../core/brain_providers.dart';
import '../../shared/date_text.dart';

/// 되돌리기·휴지통 (설계서 3.0 E5). 최근 작업 묶음을 무엇을 했는지와 함께 보여 주고 되돌린다.
/// 휴지통(`_meta/trash/`)은 쌓이기만 해서 30일 지난 묶음을 비울 수 있게 한다 (확인 후, 되돌릴 수 없음).
class UndoTrashCard extends ConsumerStatefulWidget {
  const UndoTrashCard({super.key});

  @override
  ConsumerState<UndoTrashCard> createState() => _UndoTrashCardState();
}

class _UndoTrashCardState extends ConsumerState<UndoTrashCard> {
  static const keepDays = 30;
  String? _message;

  /// 묶음 id → "추가 2 · 상태 1" 같은 요약 (변경 기록에서).
  Map<String, String> _summaries(Vault vault) {
    final counts = <String, Map<String, int>>{};
    for (final e in readChangeHistory(vault)) {
      final byAction = counts.putIfAbsent(e.batch, () => {});
      byAction[e.action] = (byAction[e.action] ?? 0) + 1;
    }
    const names = {'add': '추가', 'write': '고침', 'update': '고침', 'status': '상태', 'move': '옮김', 'delete': '지움', 'lint-fix': '형식', 'import': '가져옴'};
    return {
      for (final MapEntry(:key, :value) in counts.entries)
        key: value.entries.map((e) => '${names[e.key] ?? e.key} ${e.value}').join(' · '),
    };
  }

  /// 휴지통 묶음 폴더 중 [keepDays]일 지난 것.
  List<Directory> _oldTrash(Vault vault) {
    final root = Directory(p.join(vault.metaDir, 'trash'));
    if (!root.existsSync()) return const [];
    final limit = DateTime.now().subtract(const Duration(days: keepDays));
    return [
      for (final dir in root.listSync().whereType<Directory>())
        if (dir.statSync().modified.isBefore(limit)) dir,
    ];
  }

  int _trashFiles(Vault vault) {
    final root = Directory(p.join(vault.metaDir, 'trash'));
    return root.existsSync() ? root.listSync(recursive: true).whereType<File>().length : 0;
  }

  void _undo(Vault vault, UndoBatch batch) {
    try {
      final count = undoBatch(vault, batch.id);
      setState(() => _message = '${batch.id} 되돌림: 파일 $count개');
      bumpVault(ref);
    } on Object catch (e) {
      setState(() => _message = '되돌리지 못함: $e');
    }
  }

  Future<void> _emptyOld(Vault vault, List<Directory> old) async {
    final isOk = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog.alert(
        title: const Text('휴지통을 비울까요?'),
        description: Text('$keepDays일 지난 묶음 ${old.length}개를 완전히 지웁니다. 되돌릴 수 없습니다.'),
        actions: [
          ShadButton.outline(child: const Text('취소'), onPressed: () => Navigator.of(context).pop(false)),
          ShadButton.destructive(child: const Text('비우기'), onPressed: () => Navigator.of(context).pop(true)),
        ],
      ),
    );
    if (isOk != true) return;
    var removed = 0;
    for (final dir in old) {
      try {
        dir.deleteSync(recursive: true);
        removed++;
      } on FileSystemException catch (e) {
        debugPrint('[휴지통] 못 지움: ${dir.path} $e');
      }
    }
    setState(() => _message = '휴지통 묶음 $removed개를 비웠습니다');
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    ref.watch(vaultRevisionProvider);
    final vault = ref.watch(vaultProvider);
    final batches = recentBatches(vault);
    final summaries = _summaries(vault);
    final old = _oldTrash(vault);
    String time(DateTime d) => stamp(d);
    return ShadCard(
      title: const Text('되돌리기·휴지통'),
      description: const Text('앱·brain 명령·AI가 한 작업은 묶음으로 남습니다. 묶음을 통째로 되돌리면 고친 파일은 되살리고 새로 생긴 파일은 휴지통으로 옮깁니다.'),
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (batches.isEmpty) Text('되돌릴 작업 묶음이 없습니다.', style: theme.textTheme.muted),
            for (final b in batches)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${time(b.at)}  ${summaries[b.id] ?? b.id}  · 파일 ${b.files}개${b.isUndone ? '  (되돌림)' : ''}',
                      style: theme.textTheme.small,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!b.isUndone)
                    ShadButton.ghost(size: ShadButtonSize.sm, onPressed: () => _undo(vault, b), child: const Text('되돌리기')),
                ],
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text('휴지통 파일 ${_trashFiles(vault)}개 · $keepDays일 지난 묶음 ${old.length}개', style: theme.textTheme.muted),
                ),
                ShadButton.outline(
                  size: ShadButtonSize.sm,
                  enabled: old.isNotEmpty,
                  onPressed: () => _emptyOld(vault, old),
                  child: Text('$keepDays일 지난 것 비우기'),
                ),
              ],
            ),
            if (_message != null) ...[const SizedBox(height: 8), Text(_message!, style: theme.textTheme.small)],
          ],
        ),
      ),
    );
  }
}
