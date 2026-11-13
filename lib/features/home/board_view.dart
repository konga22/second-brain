import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/background_tasks.dart';
import '../../core/brain_providers.dart';

/// 정리 보드 (설계서 3.3): 원본 → 정리 대기 → 정리됨 → 점검 필요.
class BoardView extends ConsumerWidget {
  const BoardView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(notesProvider);
    final raw = ref.watch(rawDocsProvider);
    final issues = ref.watch(lintIssuesProvider).value ?? const <LintIssue>[];
    final byId = {for (final d in notes) d.id: d};
    final similarAsync = ref.watch(draftSimilarProvider);
    final similar = similarAsync.value ?? const <String, List<SimilarNote>>{};
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
            hint: similarAsync.hasError
                ? 'AI 초안 — 비슷한 노트를 찾지 못함 (${similarAsync.error})'
                : 'AI 초안 — 확인하면 정리됨, 이미 있는 지식이면 합치기',
            cards: [
              for (final d in notes)
                if (d.isDraft)
                  _CardData(
                    d.id,
                    d.title,
                    d.summary,
                    extra: similar[d.id] == null
                        ? null
                        : DraftSimilarList(
                            similar: similar[d.id]!,
                            onOpen: open,
                            onMerge: (s) => _merge(context, ref, d, s.doc),
                          ),
                  ),
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

  /// [합치기] (설계서_프롬프트이후 4.2): 묻고, 초안 본문을 [target] 끝에 붙이고 초안은 "합쳐짐"으로 남긴다.
  Future<void> _merge(BuildContext context, WidgetRef ref, IndexedDoc draft, IndexedDoc target) async {
    final isOk = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('초안을 합칠까요?'),
        description: Text(
          '${draft.title}의 본문을 ${target.title} 끝에 붙입니다. 초안은 지우지 않고 "합쳐짐"으로 남아 그 노트를 가리킵니다. '
          '설정 → 되돌리기에서 한 번에 되돌릴 수 있습니다.',
        ),
        actions: [
          ShadButton.outline(onPressed: () => Navigator.of(context).pop(false), child: const Text('취소')),
          ShadButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('합치기')),
        ],
      ),
    );
    if (isOk != true || !context.mounted) return;
    final vault = ref.read(vaultProvider);
    final revision = ref.read(vaultRevisionProvider.notifier);
    final toaster = ShadToaster.maybeOf(context);
    try {
      await changeNoteInBackground(
        vault.root,
        vault.indexPath,
        change: NoteChange.mergeInto,
        id: draft.id,
        targetId: target.id,
        batch: newBatchId(),
      );
      toaster?.show(ShadToast(description: Text('${target.title}에 합쳤습니다.')));
    } on Object catch (e) {
      toaster?.show(ShadToast.destructive(description: Text('합치지 못했습니다: ${e is NoteStoreException ? e.message : e}')));
    } finally {
      revision.bump(); // 실패해도 일부(충돌 사본 등)가 바뀌었을 수 있다
    }
  }
}

/// 정리 대기 카드의 "비슷한 정리된 노트" 줄 (설계서_프롬프트이후 4.2): 제목, [옆에 열기], [합치기].
/// 이미 있는 내용인지 사용자가 직접 찾지 않게 한다. 점수는 추천 연결과 같은 핵심 단어 겹침이다(AI 호출 없음).
class DraftSimilarList extends StatelessWidget {
  const DraftSimilarList({super.key, required this.similar, required this.onOpen, required this.onMerge});

  final List<SimilarNote> similar;
  final void Function(String id) onOpen;
  final void Function(SimilarNote similar) onMerge;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('비슷한 정리된 노트', style: theme.textTheme.muted.copyWith(fontSize: 11)),
          for (final s in similar.take(2))
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${s.doc.title}  (${s.shared}/${s.terms})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  height: 22,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  onPressed: () => onOpen(s.doc.id),
                  child: const Text('옆에 열기', style: TextStyle(fontSize: 11)),
                ),
                ShadButton.outline(
                  size: ShadButtonSize.sm,
                  height: 22,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  onPressed: () => onMerge(s),
                  child: const Text('합치기', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _CardData {
  const _CardData(this.id, this.title, this.detail, {this.extra});

  final String id;
  final String title;
  final String detail;

  /// 카드 아래에 붙는 줄 (비슷한 노트, 점검 버튼).
  final Widget? extra;
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
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: title, style: theme.textTheme.small),
                  TextSpan(text: '  ${cards.length}', style: theme.textTheme.muted),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(hint, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.muted.copyWith(fontSize: 11)),
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
                                  ?card.extra,
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
