import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';

/// 노트 화면. 정리 대기(초안)를 위에 두고, 확인하면 정리됨으로 바꾼다 (설계서 4.1 초안).
class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  bool _isDraftOnly = false;

  void _onConfirm(IndexedDoc doc) {
    ref.read(noteStoreProvider).setStatus(doc.id, NoteStatus.active);
  }

  void _onOpen(IndexedDoc doc) {
    final vault = ref.read(vaultProvider);
    final text = File(p.join(vault.root, doc.path)).readAsStringSync();
    final note = Note.parse(text, fallbackId: doc.id, fallbackTitle: doc.title);
    showShadDialog<void>(
      context: context,
      builder: (context) => ShadDialog(
        title: Text(note.title),
        description: Text('${doc.id} · ${doc.folder} · 출처 ${note.source}'),
        actions: [
          if (doc.isDraft)
            ShadButton(
              onPressed: () {
                _onConfirm(doc);
                Navigator.of(context).pop();
              },
              child: const Text('확인 → 정리됨'),
            ),
        ],
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420, maxWidth: 560),
          child: SingleChildScrollView(child: SelectableText(note.body.trim())),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final notes = ref.watch(notesProvider);
    return notes.when(
      loading: () => const Center(child: Text('노트를 읽는 중…')),
      error: (e, _) => Center(child: Text('노트를 읽지 못했습니다: $e')),
      data: (docs) {
        final drafts = docs.where((d) => d.isDraft).length;
        final shown = _isDraftOnly
            ? docs.where((d) => d.isDraft).toList()
            : docs;
        return ListView(
          padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
          children: [
            Row(
              children: [
                Text('노트', style: theme.textTheme.h4),
                const SizedBox(width: 12),
                Text(
                  '전체 ${docs.length} · 정리 대기 $drafts',
                  style: theme.textTheme.muted,
                ),
                const Spacer(),
                ShadButton.outline(
                  size: ShadButtonSize.sm,
                  onPressed: () => setState(() => _isDraftOnly = !_isDraftOnly),
                  child: Text(_isDraftOnly ? '전체 보기' : '정리 대기만'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 40),
                child: Center(
                  child: Text(
                    docs.isEmpty
                        ? '아직 노트가 없습니다. Claude Code에서 "지식 저장해 줘"라고 하거나, 연동·설정에서 지난 대화를 정리하세요.'
                        : '정리 대기 노트가 없습니다.',
                    style: theme.textTheme.muted,
                  ),
                ),
              ),
            for (final doc in shown)
              _NoteRow(
                doc: doc,
                onOpen: () => _onOpen(doc),
                onConfirm: () => _onConfirm(doc),
              ),
          ],
        );
      },
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.doc,
    required this.onOpen,
    required this.onConfirm,
  });

  final IndexedDoc doc;
  final VoidCallback onOpen;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    return GestureDetector(
      onTap: onOpen,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.border),
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
                      style: theme.textTheme.muted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text('${doc.id} · ${doc.folder}', style: theme.textTheme.muted),
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
