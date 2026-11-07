import 'package:brain_core/brain_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../app/router/app_page.dart';
import '../app/theme/app_colors.dart';
import '../core/brain_providers.dart';
import '../features/notes/note_editor_dialog.dart';

/// ⌘K 명령 창 (설계서 3.2): 노트 찾기·화면 이동·새 노트를 한 곳에서.
Future<void> showCommandPalette(BuildContext context) => showShadDialog<void>(
  context: context,
  builder: (context) => const _CommandPalette(),
);

class _Command {
  const _Command(this.label, this.icon, this.run, {this.hint = ''});

  final String label;
  final IconData icon;
  final String hint;
  final void Function(BuildContext context, WidgetRef ref) run;
}

class _CommandPalette extends ConsumerStatefulWidget {
  const _CommandPalette();

  @override
  ConsumerState<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<_CommandPalette> {
  String _query = '';
  int _cursor = 0;

  List<_Command> _commands(List<IndexedDoc> hits) {
    final q = _query.trim();
    final pages = [
      for (final page in AppPage.values)
        if (q.isEmpty || page.label.contains(q))
          _Command(
            '${page.label}(으)로 이동',
            page.icon,
            (context, ref) => context.go(page.path),
          ),
    ];
    return [
      for (final doc in hits)
        _Command(
          doc.title,
          doc.isDraft ? LucideIcons.fileClock : LucideIcons.fileText,
          (context, ref) {
            ref.read(selectedNoteProvider.notifier).select(doc.id);
          },
          hint: '${doc.id} · ${doc.topic}',
        ),
      _Command(
        q.isEmpty ? '새 노트' : '새 노트: "$q"',
        LucideIcons.plus,
        (context, ref) =>
            showNoteEditor(context, initialTitle: q.isEmpty ? null : q),
        hint: '⌘N',
      ),
      ...pages,
    ];
  }

  void _run(_Command command) {
    final navigator = Navigator.of(context);
    final rootContext = navigator.context;
    navigator.pop();
    command.run(rootContext, ref);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final hits = _query.trim().isEmpty
        ? ref.watch(notesProvider).take(5).toList()
        : ref.watch(searchIndexProvider).search(_query, limit: 8);
    final commands = _commands(hits);
    final cursor = commands.isEmpty ? 0 : _cursor.clamp(0, commands.length - 1);
    return ShadDialog(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.all(12),
      closeIcon: const SizedBox.shrink(),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              setState(() => _cursor = (cursor + 1) % commands.length),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => setState(
            () => _cursor = (cursor - 1 + commands.length) % commands.length,
          ),
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShadInput(
              autofocus: true,
              placeholder: const Text('노트 찾기, 화면 이동, 새 노트…'),
              leading: const Icon(LucideIcons.search, size: 14),
              onChanged: (value) => setState(() {
                _query = value;
                _cursor = 0;
              }),
              onSubmitted: (_) {
                if (commands.isNotEmpty) _run(commands[cursor]);
              },
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (i, command) in commands.indexed)
                    GestureDetector(
                      onTap: () => _run(command),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: i == cursor ? colors.accentSoft : null,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              command.icon,
                              size: 14,
                              color: colors.textMuted,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                command.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(command.hint, style: theme.textTheme.muted),
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
