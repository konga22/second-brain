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
    final aiEditsAsync = ref.watch(aiEditsProvider);
    final aiEdits = aiEditsAsync.value ?? const <AiEdit>[];
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
            hint: aiEditsAsync.hasError
                ? 'AI가 고친 노트를 읽지 못함 (${aiEditsAsync.error}) · brain lint'
                : 'AI가 고친 노트 · brain lint (고아 노트 제외)',
            cards: [
              for (final edit in aiEdits)
                _CardData(
                  edit.noteId,
                  'AI가 고친 노트: ${edit.title}',
                  aiEditDetail(edit),
                  extra: AiEditActions(
                    edit: edit,
                    onShowDiff: () => _showDiff(context, ref, edit),
                    onRevert: () => _revert(context, ref, edit),
                    onAcknowledge: () {
                      AiEditReview(ref.read(vaultProvider), ref.read(searchIndexProvider)).acknowledge(edit);
                      bumpVault(ref);
                    },
                  ),
                ),
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

  /// [바뀐 내용 보기] (설계서_프롬프트이후 4.3): AI가 처음 고치기 전과 지금의 줄 차이.
  Future<void> _showDiff(BuildContext context, WidgetRef ref, AiEdit edit) async {
    final vault = ref.read(vaultProvider);
    final toaster = ShadToaster.maybeOf(context);
    List<DiffLine>? lines;
    try {
      lines = await aiEditDiffInBackground(vault.root, vault.indexPath, edit);
    } on Object catch (e) {
      toaster?.show(ShadToast.destructive(description: Text('바뀐 내용을 읽지 못했습니다: $e')));
      return;
    }
    if (!context.mounted) return;
    await showShadDialog<void>(
      context: context,
      builder: (context) => ShadDialog(
        title: Text('AI가 바꾼 내용: ${edit.title}'),
        description: Text(aiEditDetail(edit)),
        actions: [ShadButton.outline(onPressed: () => Navigator.of(context).pop(), child: const Text('닫기'))],
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420, maxWidth: 640),
          child: lines == null
              ? const Text('고치기 전 사본을 찾지 못했습니다 (되돌리기 묶음이 지워졌을 수 있음).')
              : SingleChildScrollView(child: DiffLines(lines: lines)),
        ),
      ),
    );
  }

  /// [되돌리기] (설계서_프롬프트이후 4.3): 묻고, 이 노트를 고친 AI 묶음을 되돌린다 (`brain undo`와 같음).
  Future<void> _revert(BuildContext context, WidgetRef ref, AiEdit edit) async {
    final isOk = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('AI가 고치기 전으로 되돌릴까요?'),
        description: Text(
          '${edit.title} — AI 작업 묶음 ${edit.batches.length}개를 되돌립니다. 그 묶음에서 함께 바뀐 파일(제목을 바꿀 때 고친 링크)도 돌아갑니다.',
        ),
        actions: [
          ShadButton.outline(onPressed: () => Navigator.of(context).pop(false), child: const Text('취소')),
          ShadButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('되돌리기')),
        ],
      ),
    );
    if (isOk != true || !context.mounted) return;
    final vault = ref.read(vaultProvider);
    final revision = ref.read(vaultRevisionProvider.notifier);
    final toaster = ShadToaster.maybeOf(context);
    try {
      final count = await revertAiEditInBackground(vault.root, vault.indexPath, edit);
      toaster?.show(ShadToast(description: Text('${edit.title}: 파일 $count개를 되돌렸습니다.')));
    } on Object catch (e) {
      final message = switch (e) {
        NoteStoreException(:final message) => message,
        ArgumentError(:final message) => '$message',
        _ => '$e',
      };
      toaster?.show(ShadToast.destructive(description: Text('되돌리지 못했습니다: $message')));
    } finally {
      revision.bump();
    }
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

/// "AI가 고친 노트" 카드의 설명 줄: 언제, 어느 대화에서, 몇 번.
String aiEditDetail(AiEdit edit) {
  String two(int n) => n.toString().padLeft(2, '0');
  final at = edit.lastAt.toLocal();
  final when = '${at.month}/${at.day} ${two(at.hour)}:${two(at.minute)}';
  final sessions = edit.sessions.isEmpty
      ? '대화 id 모름'
      : edit.sessions.map((s) => '대화 ${s.length > 8 ? s.substring(0, 8) : s}').join(', ');
  return '$when · $sessions${edit.batches.length > 1 ? ' · ${edit.batches.length}번 고침' : ''}';
}

/// "AI가 고친 노트" 카드의 버튼 (설계서_프롬프트이후 4.3): [바뀐 내용 보기], [되돌리기], [확인함].
/// 승인 전까지 막지 않고 바로 고치되(사용자 결정), 눈에 보이게 하고 되돌릴 수 있게 한다.
class AiEditActions extends StatelessWidget {
  const AiEditActions({
    super.key,
    required this.edit,
    required this.onShowDiff,
    required this.onRevert,
    required this.onAcknowledge,
  });

  final AiEdit edit;
  final VoidCallback onShowDiff;
  final VoidCallback onRevert;
  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    Widget button(String label, VoidCallback? onPressed, {bool outline = false}) => (outline ? ShadButton.outline : ShadButton.ghost)(
      size: ShadButtonSize.sm,
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 2,
            children: [
              button('바뀐 내용 보기', onShowDiff),
              button('되돌리기', edit.canRevert ? onRevert : null),
              button('확인함', onAcknowledge, outline: true),
            ],
          ),
          if (!edit.canRevert)
            Text(
              '그 뒤에 직접 고친 기록이 있어 되돌리기를 막았습니다 (직접 고친 내용까지 사라짐).',
              style: theme.textTheme.muted.copyWith(fontSize: 11),
            ),
        ],
      ),
    );
  }
}

/// 줄 차이 보기: 빠진 줄은 빨강 바탕 `-`, 새 줄은 초록 바탕 `+`.
class DiffLines extends StatelessWidget {
  const DiffLines({super.key, required this.lines});

  final List<DiffLine> lines;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final line in lines)
          Container(
            color: switch (line.kind) {
              DiffKind.added => colors.success.withValues(alpha: 0.15),
              DiffKind.removed => colors.danger.withValues(alpha: 0.15),
              DiffKind.same => null,
            },
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            child: Text(
              '${switch (line.kind) {
                DiffKind.added => '+',
                DiffKind.removed => '-',
                DiffKind.same => ' ',
              }} ${line.text}',
              style: TextStyle(fontSize: 12, fontFamily: 'Menlo', color: line.kind == DiffKind.same ? colors.textMuted : colors.text),
            ),
          ),
      ],
    );
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
