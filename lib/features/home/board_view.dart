import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';

/// 정리 보드 (설계서 3.3): 원본 → 정리 대기 → 정리됨 → 점검 필요.
class BoardView extends ConsumerWidget {
  const BoardView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(notesProvider);
    final raw = ref.watch(rawDocsProvider);
    final issues = ref.watch(lintIssuesProvider);
    final byId = {for (final d in notes) d.id: d};
    final issueByNote = <String, List<LintIssue>>{};
    for (final i in issues) {
      if (i.type == LintType.orphan) continue; // 고아는 너무 흔해서 보드에선 뺀다
      issueByNote.putIfAbsent(i.id, () => []).add(i);
    }
    void open(String id) => ref.read(selectedNoteProvider.notifier).select(id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Column(
            title: '원본',
            hint: 'raw/ — brain-ingest로 정리',
            cards: [for (final d in raw) _CardData(d.id, d.title, d.folder)],
            onOpen: open,
          ),
          _Column(
            title: '정리 대기',
            hint: 'AI 초안 — 확인하면 정리됨',
            cards: [
              for (final d in notes)
                if (d.isDraft) _CardData(d.id, d.title, d.summary),
            ],
            onOpen: open,
          ),
          _Column(
            title: '정리됨',
            hint: '최근 고친 순',
            cards: [
              for (final d in notes.where((d) => !d.isDraft && !d.isMerged).take(40))
                _CardData(d.id, d.title, d.summary),
            ],
            onOpen: open,
          ),
          _Column(
            title: '점검 필요',
            hint: 'brain lint (고아 노트 제외)',
            cards: [
              for (final e in issueByNote.entries)
                _CardData(
                  e.key,
                  byId[e.key]?.title ?? e.key,
                  e.value.map((i) => '${i.type.label}: ${i.message}').join('\n'),
                ),
            ],
            onOpen: open,
          ),
        ],
      ),
    );
  }
}

class _CardData {
  const _CardData(this.id, this.title, this.detail);

  final String id;
  final String title;
  final String detail;
}

class _Column extends ConsumerWidget {
  const _Column({required this.title, required this.hint, required this.cards, required this.onOpen});

  final String title;
  final String hint;
  final List<_CardData> cards;
  final void Function(String id) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final selected = ref.watch(selectedNoteProvider);
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colors.surfaceRaised,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(title, style: theme.textTheme.small),
                const SizedBox(width: 6),
                Text('${cards.length}', style: theme.textTheme.muted),
              ],
            ),
            Text(hint, style: theme.textTheme.muted.copyWith(fontSize: 11)),
            const SizedBox(height: 8),
            Expanded(
              child: cards.isEmpty
                  ? Center(child: Text('없음', style: theme.textTheme.muted))
                  : ListView(
                      children: [
                        for (final card in cards)
                          GestureDetector(
                            onTap: () => onOpen(card.id),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: card.id == selected ? colors.accentSoft : colors.surface,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: card.id == selected ? colors.accent : colors.border),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(card.title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                  if (card.detail.isNotEmpty)
                                    Text(
                                      card.detail,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.muted.copyWith(fontSize: 11),
                                    ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
