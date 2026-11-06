import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';
import 'note_editor_dialog.dart';

/// 노트 표 화면 (설계서 3절 `/notes`). 홈 보기와 별개. 정리 대기가 먼저 나온다.
class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  bool _isDraftOnly = false;
  String _query = '';

  void _onConfirm(IndexedDoc doc) {
    ref.read(noteStoreProvider).setStatus(doc.id, NoteStatus.active, batch: newBatchId());
    bumpVault(ref);
  }

  void _onConfirmAll(List<IndexedDoc> drafts) {
    final batch = newBatchId();
    final store = ref.read(noteStoreProvider);
    for (final doc in drafts) {
      store.setStatus(doc.id, NoteStatus.active, batch: batch);
    }
    bumpVault(ref);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final all = ref.watch(notesProvider);
    final selected = ref.watch(selectedNoteProvider);
    final drafts = all.where((d) => d.isDraft).toList();
    final List<IndexedDoc> shown;
    if (_query.trim().isNotEmpty) {
      shown = ref
          .watch(searchIndexProvider)
          .search(_query, limit: 50)
          .where((d) => !_isDraftOnly || d.isDraft)
          .toList();
    } else {
      shown = _isDraftOnly ? drafts : all;
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
      children: [
        Row(
          children: [
            Text('노트', style: theme.textTheme.h4),
            const SizedBox(width: 12),
            Text(
              '전체 ${all.length} · 정리 대기 ${drafts.length}',
              style: theme.textTheme.muted,
            ),
            const Spacer(),
            ShadButton(
              size: ShadButtonSize.sm,
              leading: const Icon(LucideIcons.plus, size: 14),
              onPressed: () => showNoteEditor(context),
              child: const Text('새 노트 ⌘N'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ShadInput(
                placeholder: const Text('찾기 (띄어쓰기·조사 상관없음)'),
                leading: const Icon(LucideIcons.search, size: 14),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            const SizedBox(width: 8),
            ShadButton.outline(
              size: ShadButtonSize.sm,
              onPressed: () => setState(() => _isDraftOnly = !_isDraftOnly),
              child: Text(_isDraftOnly ? '전체 보기' : '정리 대기만'),
            ),
            if (drafts.isNotEmpty) ...[
              const SizedBox(width: 8),
              ShadButton.secondary(
                size: ShadButtonSize.sm,
                onPressed: () => _onConfirmAll(drafts),
                child: Text('대기 ${drafts.length}개 모두 확인'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Center(
              child: Text(
                all.isEmpty
                    ? '아직 노트가 없습니다. [새 노트]를 누르거나, Claude Code에서 "지식 저장해 줘"라고 하거나, 연동·설정에서 지난 대화를 정리하세요.'
                    : (_query.isEmpty ? '정리 대기 노트가 없습니다.' : '찾은 노트가 없습니다. 검색어를 바꿔 보세요.'),
                style: theme.textTheme.muted,
              ),
            ),
          ),
        for (final doc in shown)
          _NoteRow(
            doc: doc,
            isSelected: doc.id == selected,
            onOpen: () => ref.read(selectedNoteProvider.notifier).select(doc.id),
            onConfirm: () => _onConfirm(doc),
          ),
      ],
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.doc,
    required this.isSelected,
    required this.onOpen,
    required this.onConfirm,
  });

  final IndexedDoc doc;
  final bool isSelected;
  final VoidCallback onOpen;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    return GestureDetector(
      onTap: onOpen,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? colors.accentSoft : colors.surface,
          border: Border.all(color: isSelected ? colors.accent : colors.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            if (doc.isDraft) ...[
              ShadBadge.secondary(child: const Text('정리 대기')),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(doc.title, style: theme.textTheme.small),
                  if (doc.summary.isNotEmpty)
                    Text(
                      doc.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.muted,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text('${doc.id} · ${doc.topic}', style: theme.textTheme.muted),
            if (doc.isDraft) ...[
              const SizedBox(width: 12),
              ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: onConfirm,
                child: const Text('확인'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
