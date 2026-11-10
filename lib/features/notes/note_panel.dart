import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../shared/date_text.dart';
import '../../core/brain_providers.dart';
import '../../shared/markdown_view.dart';
import 'note_editor_dialog.dart';

/// 오른쪽 노트 패널 (설계서 3.2 3단 배치). 어느 화면에서든 노트를 고르면 여기 열린다.
class NotePanel extends ConsumerWidget {
  const NotePanel({super.key, this.width = 340, this.onClose});

  final double width;

  /// 패널 닫기 (⌘\\). 고른 노트는 그대로 두어 다시 열면 이어 본다.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final id = ref.watch(selectedNoteProvider);
    ref.watch(vaultRevisionProvider);
    return Container(
      width: width,
      color: colors.surface,
      child: Stack(
        children: [
          Positioned.fill(
            child: id == null
                ? Center(
                    child: Text(
                      '노트를 고르면 여기에 열립니다',
                      style: ShadTheme.of(context).textTheme.muted,
                    ),
                  )
                : _NoteDetail(id: id),
          ),
          if (onClose != null)
            Positioned(
              top: 8,
              right: 8,
              child: ShadTooltip(
                builder: (_) => const Text('패널 닫기 (⌘\\)'),
                child: ShadIconButton.ghost(
                  width: 26,
                  height: 26,
                  icon: const Icon(LucideIcons.panelRightClose, size: 15),
                  onPressed: onClose,
                ),
              ),
            ),
        ],
      ),
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
    final origins = resolveOrigins(ref.watch(vaultProvider), note);
    final links = [
      for (final link in ref.watch(linksProvider))
        if (link.fromId == id || link.toId == id)
          (link, link.fromId == id ? link.toId : link.fromId),
    ];
    final relatedLessons = isRaw
        ? const <Lesson>[]
        : ref.watch(lessonStoreProvider).match('${note.title} ${note.summary}');
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 36, 20, 24),
      children: [
        Row(
          children: [
            Icon(LucideIcons.folder, size: 13, color: colors.textFaint),
            const SizedBox(width: 4),
            Expanded(child: Text(doc.folder, style: theme.textTheme.muted.copyWith(fontSize: 12))),
            Text(doc.id, style: theme.textTheme.muted.copyWith(fontSize: 12, fontFamily: 'Menlo')),
            const SizedBox(width: 30),
          ],
        ),
        const SizedBox(height: 8),
        Text(note.title, style: theme.textTheme.h4),
        if (doc.isDraft || isRaw)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                if (doc.isDraft) ShadBadge.secondary(child: const Text('정리 대기')),
                if (isRaw) ShadBadge.outline(child: const Text('원본')),
              ],
            ),
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
        const SizedBox(height: 6),
        Text(
          '출처 ${origins.isEmpty ? note.source : origins.first.shortLabel} · 만듦 ${stamp(note.created ?? doc.mtime)} · 고침 ${stamp(note.updated ?? note.created ?? doc.mtime)} · 연결 ${links.length}',
          style: theme.textTheme.muted.copyWith(fontSize: 12),
        ),
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
        MarkdownView(
          text: note.body.trim().isEmpty ? '(본문 없음)' : note.body.trim(),
          onLink: (title) {
            final target = index.byTitle(title);
            if (target != null) ref.read(selectedNoteProvider.notifier).select(target.id);
          },
        ),
        if (links.any((l) => !l.$1.isSuggested)) ...[
          const SizedBox(height: 20),
          _SectionTitle(icon: LucideIcons.link, label: '연결된 노트'),
          for (final (link, otherId) in links)
            if (!link.isSuggested)
              if (index.byId(otherId) case final other?)
                _LinkRow(
                  other: other,
                  isSuggested: false,
                  onOpen: () => ref.read(selectedNoteProvider.notifier).select(otherId),
                ),
        ],
        if (links.any((l) => l.$1.isSuggested)) ...[
          const SizedBox(height: 16),
          _SectionTitle(icon: LucideIcons.sparkles, label: '추천 연결 — 확정하면 본문에 [[제목]]으로 써요'),
          for (final (link, otherId) in links)
            if (link.isSuggested)
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
          _SectionTitle(icon: LucideIcons.fileText, label: '출처 — 이 지식이 나온 곳'),
          for (final origin in origins)
            _OriginRow(
              origin: origin,
              onOpen: origin.rawId != null && origin.rawId != id && index.byId(origin.rawId!) != null
                  ? () => ref.read(selectedNoteProvider.notifier).select(origin.rawId)
                  : null,
            ),
        ],
        if (relatedLessons.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionTitle(icon: LucideIcons.lightbulb, label: '관련 실수 노트'),
          for (final lesson in relatedLessons)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: colors.surfaceRaised, borderRadius: BorderRadius.circular(8)),
              child: Text('${lesson.trigger} → ${lesson.action}  ${lesson.id}', style: const TextStyle(fontSize: 12)),
            ),
        ],
      ],
    );
  }
}


/// 출처 한 건: 도구·프로젝트 / 세션 제목 / 날짜·세션 id·대화 수 / 경로. 원본이 있으면 눌러서 연다.
class _OriginRow extends StatelessWidget {
  const _OriginRow({required this.origin, this.onOpen});

  final NoteOrigin origin;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final muted = TextStyle(fontSize: 11, color: colors.textMuted);
    final isSession = origin.kind == NoteOriginKind.session;
    final box = Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: colors.surfaceRaised, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isSession ? LucideIcons.messagesSquare : LucideIcons.fileText,
                size: 13,
                color: colors.accentText,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  origin.shortLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              if (onOpen != null) Text('원본 열기', style: TextStyle(fontSize: 11, color: colors.accentText)),
            ],
          ),
          if (isSession && origin.title != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                origin.title!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (origin.detail.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 3), child: Text(origin.detail, style: muted)),
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              origin.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: colors.textFaint, fontFamily: 'Menlo'),
            ),
          ),
        ],
      ),
    );
    if (onOpen == null) return box;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onOpen, child: box),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 13, color: colors.textMuted),
          const SizedBox(width: 6),
          Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: colors.textMuted))),
        ],
      ),
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
            ShadButton(size: ShadButtonSize.sm, height: 24, onPressed: onAccept, child: const Text('연결')),
          if (onDismiss != null) ...[
            const SizedBox(width: 4),
            ShadButton.outline(size: ShadButtonSize.sm, height: 24, onPressed: onDismiss, child: const Text('거절')),
          ],
        ],
      ),
    );
  }
}
