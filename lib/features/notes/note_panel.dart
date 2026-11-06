import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';
import 'note_editor_dialog.dart';

/// 오른쪽 노트 패널 (설계서 3.2 3단 배치). 어느 화면에서든 노트를 고르면 여기 열린다.
class NotePanel extends ConsumerWidget {
  const NotePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final id = ref.watch(selectedNoteProvider);
    ref.watch(vaultRevisionProvider);
    return Container(
      width: 340,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.border)),
      ),
      child: id == null
          ? Center(
              child: Text(
                '노트를 고르면 여기에 열립니다',
                style: ShadTheme.of(context).textTheme.muted,
              ),
            )
          : _NoteDetail(id: id),
    );
  }
}

class _NoteDetail extends ConsumerWidget {
  const _NoteDetail({required this.id});

  final String id;

  Future<void> _onDelete(BuildContext context, WidgetRef ref, IndexedDoc doc) async {
    final isConfirmed = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('노트를 지울까요?'),
        description: Text(
          '${doc.title} — 바로 지우지 않고 휴지통(_meta/trash)으로 옮깁니다. brain undo로 되살릴 수 있습니다.',
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('지우기'),
          ),
        ],
      ),
    );
    if (isConfirmed != true) return;
    ref.read(noteStoreProvider).delete(doc.id);
    ref.read(selectedNoteProvider.notifier).select(null);
    bumpVault(ref);
  }

  void _onConfirm(WidgetRef ref) {
    ref.read(noteStoreProvider).setStatus(id, NoteStatus.active, batch: newBatchId());
    bumpVault(ref);
  }

  /// 추천 연결을 확정: 이 노트 본문 끝에 `[[제목]]`을 붙여 manual 연결로 만든다.
  void _onAcceptLink(WidgetRef ref, IndexedDoc other) {
    final store = ref.read(noteStoreProvider);
    final found = store.read(id);
    if (found == null) return;
    final (_, note, hash) = found;
    store.update(
      id,
      expectHash: hash,
      title: note.title,
      summary: note.summary,
      body: '${note.body.trimRight()}\n\n관련: [[${other.title}]]\n',
      tags: note.tags,
      aliases: note.aliases,
    );
    bumpVault(ref);
  }

  void _onDismissLink(WidgetRef ref, String otherId) {
    DismissedLinks(ref.read(vaultProvider)).add(id, otherId);
    bumpVault(ref);
  }

  void _onReveal(WidgetRef ref, IndexedDoc doc) {
    Process.run('open', ['-R', p.join(ref.read(vaultProvider).root, doc.path)]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final index = ref.watch(searchIndexProvider);
    final doc = index.byId(id);
    if (doc == null) {
      return Center(child: Text('노트가 없습니다 ($id)', style: theme.textTheme.muted));
    }
    final file = File(p.join(ref.watch(vaultProvider).root, doc.path));
    final text = file.existsSync() ? file.readAsStringSync() : '';
    final note = Note.parse(text, fallbackId: doc.id, fallbackTitle: doc.title);
    final isRaw = doc.kind == 'raw';
    final links = [
      for (final link in ref.watch(linksProvider))
        if (link.fromId == id || link.toId == id)
          (link, link.fromId == id ? link.toId : link.fromId),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 36, 20, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(note.title, style: theme.textTheme.h4)),
            ShadIconButton.ghost(
              width: 26,
              height: 26,
              icon: const Icon(LucideIcons.x, size: 14),
              onPressed: () => ref.read(selectedNoteProvider.notifier).select(null),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${doc.id} · ${doc.folder}', style: theme.textTheme.muted),
            if (doc.isDraft) ShadBadge.secondary(child: const Text('정리 대기')),
            if (isRaw) ShadBadge.outline(child: const Text('원본')),
          ],
        ),
        if (note.summary.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(note.summary, style: theme.textTheme.small),
        ],
        if (note.tags.isNotEmpty || note.aliases.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final t in note.tags) ShadBadge.outline(child: Text('#$t')),
              for (final a in note.aliases)
                ShadBadge.outline(child: Text('= $a')),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (!isRaw)
              ShadButton.outline(
                size: ShadButtonSize.sm,
                leading: const Icon(LucideIcons.pencil, size: 14),
                onPressed: () => showNoteEditor(context, noteId: id),
                child: const Text('고치기'),
              ),
            if (doc.isDraft)
              ShadButton(
                size: ShadButtonSize.sm,
                onPressed: () => _onConfirm(ref),
                child: const Text('확인 → 정리됨'),
              ),
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              leading: const Icon(LucideIcons.folderOpen, size: 14),
              onPressed: () => _onReveal(ref, doc),
              child: const Text('Finder'),
            ),
            if (!isRaw)
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                leading: Icon(LucideIcons.trash2, size: 14, color: colors.danger),
                onPressed: () => _onDelete(context, ref, doc),
                child: Text('지우기', style: TextStyle(color: colors.danger)),
              ),
          ],
        ),
        if (isRaw)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '원본은 고치지 않습니다. Claude Code에서 "가져온 거 정리해 줘"라고 하면 brain-ingest가 정리 대기 노트로 만듭니다.',
              style: theme.textTheme.muted,
            ),
          ),
        const SizedBox(height: 16),
        Container(height: 1, color: colors.border),
        const SizedBox(height: 12),
        SelectableText(
          note.body.trim().isEmpty ? '(본문 없음)' : note.body.trim(),
          style: theme.textTheme.p.copyWith(fontSize: 13, height: 1.6),
        ),
        if (links.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('연결 ${links.length}', style: theme.textTheme.small),
          const SizedBox(height: 6),
          for (final (link, otherId) in links)
            if (index.byId(otherId) case final other?)
              _LinkRow(
                other: other,
                isSuggested: link.isSuggested,
                onOpen: () =>
                    ref.read(selectedNoteProvider.notifier).select(otherId),
                onAccept: link.isSuggested && !isRaw
                    ? () => _onAcceptLink(ref, other)
                    : null,
                onDismiss: link.isSuggested
                    ? () => _onDismissLink(ref, otherId)
                    : null,
              ),
        ],
        if (note.sources.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('근거: ${note.sources.join(', ')}', style: theme.textTheme.muted),
        ],
      ],
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.other,
    required this.isSuggested,
    required this.onOpen,
    this.onAccept,
    this.onDismiss,
  });

  final IndexedDoc other;
  final bool isSuggested;
  final VoidCallback onOpen;
  final VoidCallback? onAccept;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Icon(
            isSuggested ? LucideIcons.sparkles : LucideIcons.link,
            size: 13,
            color: isSuggested ? colors.textFaint : colors.accentText,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: GestureDetector(
              onTap: onOpen,
              child: Text(
                other.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: isSuggested ? colors.textMuted : colors.accentText,
                ),
              ),
            ),
          ),
          if (onAccept != null)
            ShadTooltip(
              builder: (_) => const Text('[[링크]]로 확정'),
              child: ShadIconButton.ghost(
                width: 24,
                height: 24,
                icon: const Icon(LucideIcons.check, size: 13),
                onPressed: onAccept,
              ),
            ),
          if (onDismiss != null)
            ShadTooltip(
              builder: (_) => const Text('이 추천 거절 (다시 추천 안 함)'),
              child: ShadIconButton.ghost(
                width: 24,
                height: 24,
                icon: const Icon(LucideIcons.x, size: 13),
                onPressed: onDismiss,
              ),
            ),
        ],
      ),
    );
  }
}
