import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';

/// 타임라인 (설계서 3.3): 날짜별로 쌓이고 고쳐진 일, 이번 주 숫자와 7일 막대. `_log/`에서 만든다.
class TimelineView extends ConsumerWidget {
  const TimelineView({super.key});

  static const _labels = {
    'add': '새 노트',
    'update': '고침',
    'write': '고침',
    'rename': '이름 바꿈',
    'relink': '링크 고침',
    'status': '상태',
    'delete': '지움',
    'undo': '되돌림',
    'lint-fix': '형식 채움',
    'lesson-add': '실수 노트',
    'lesson-status': '실수 노트 상태',
    'lesson-evidence': '규칙 근거',
    'lesson-update': '실수 노트 고침',
    'verifier-add': '검사 기준',
    'todo-add': '할 일',
    'todo-done': '할 일 끝',
    'todo-undo': '할 일 되살림',
    'todo-remove': '할 일 지움',
    'import': '가져옴',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final events = ref.watch(changeHistoryProvider);
    final index = ref.watch(searchIndexProvider);
    if (events.isEmpty) {
      return Center(child: Text('아직 기록이 없습니다.', style: theme.textTheme.muted));
    }
    final today = DateTime.now();
    final days = [
      for (var i = 6; i >= 0; i--) DateTime(today.year, today.month, today.day - i),
    ];
    int countOn(DateTime day) => events
        .where((e) => e.at.toLocal().year == day.year && e.at.toLocal().month == day.month && e.at.toLocal().day == day.day)
        .length;
    final week = events.where((e) => today.difference(e.at).inDays < 7).toList();
    final maxDay = days.map(countOn).fold<int>(1, (a, b) => a > b ? a : b);
    final byDate = <String, List<ChangeEvent>>{};
    for (final e in events.take(300)) {
      final t = e.at.toLocal();
      byDate.putIfAbsent('${t.month}월 ${t.day}일', () => []).add(e);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _Stat(label: '이번 주 새 노트', value: week.where((e) => e.action == 'add').length),
            _Stat(label: '고침', value: week.where((e) => {'update', 'write', 'rename'}.contains(e.action)).length),
            _Stat(label: '정리됨', value: week.where((e) => e.action == 'status' && e.detail.contains(' active')).length),
            _Stat(label: '실수 노트', value: week.where((e) => e.action == 'lesson-add').length),
            const Spacer(),
            for (final day in days)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Column(
                  children: [
                    Container(
                      width: 14,
                      height: 4 + 40 * countOn(day) / maxDay,
                      decoration: BoxDecoration(
                        color: colors.accent.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('${day.day}', style: theme.textTheme.muted.copyWith(fontSize: 10)),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        for (final entry in byDate.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 6),
            child: Text(entry.key, style: theme.textTheme.small),
          ),
          for (final e in entry.value)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${e.at.toLocal().hour.toString().padLeft(2, '0')}:${e.at.toLocal().minute.toString().padLeft(2, '0')}',
                      style: theme.textTheme.muted,
                    ),
                  ),
                  SizedBox(
                    width: 96,
                    child: Text(_labels[e.action] ?? e.action, style: TextStyle(fontSize: 12, color: colors.accentText)),
                  ),
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final id = e.targetId;
                        final doc = id == null ? null : index.byId(id);
                        return GestureDetector(
                          onTap: doc == null ? null : () => ref.read(selectedNoteProvider.notifier).select(doc.id),
                          child: Text(
                            doc == null ? e.detail : '${doc.title}  ·  ${e.detail}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: doc == null ? colors.textMuted : colors.text),
                          ),
                        );
                      },
                    ),
                  ),
                  Text(
                    e.batch.startsWith('s_') ? '세션 ${e.batch.substring(2)}' : '',
                    style: theme.textTheme.muted.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value', style: theme.textTheme.h3),
          Text(label, style: theme.textTheme.muted),
        ],
      ),
    );
  }
}
