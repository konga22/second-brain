import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';

/// 할 일 (설계서 3절 `/todos`): `todos.md` 체크리스트 + 노트에서 가져온 할 일.
class TodosPage extends ConsumerStatefulWidget {
  const TodosPage({super.key});

  @override
  ConsumerState<TodosPage> createState() => _TodosPageState();
}

class _TodosPageState extends ConsumerState<TodosPage> {
  final _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _run(void Function(TodoStore store) action) {
    try {
      action(ref.read(todoStoreProvider));
      setState(() => _error = null);
    } on StateError catch (e) {
      setState(() => _error = e.message);
    }
    bumpVault(ref);
  }

  void _onAdd() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _run((store) => store.add(text, batch: newBatchId()));
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    ref.watch(vaultRevisionProvider);
    final store = ref.watch(todoStoreProvider);
    final todos = store.list();
    final fromNotes = store.fromNotes();
    final open = todos.where((t) => !t.isDone).toList();
    final done = todos.where((t) => t.isDone).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
      children: [
        Row(
          children: [
            Text('할 일', style: theme.textTheme.h4),
            const SizedBox(width: 12),
            Text('남은 ${open.length} · 끝 ${done.length}', style: theme.textTheme.muted),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ShadInput(
                controller: _input,
                placeholder: const Text('할 일 추가 (Enter)'),
                onSubmitted: (_) => _onAdd(),
              ),
            ),
            const SizedBox(width: 8),
            ShadButton(size: ShadButtonSize.sm, onPressed: _onAdd, child: const Text('추가')),
          ],
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!)),
        const SizedBox(height: 12),
        for (final todo in [...open, ...done])
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                ShadCheckbox(value: todo.isDone, onChanged: (_) => _run((s) => s.toggle(todo, batch: newBatchId()))),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    todo.text,
                    style: TextStyle(
                      fontSize: 13,
                      color: todo.isDone ? colors.textFaint : colors.text,
                      decoration: todo.isDone ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                ShadIconButton.ghost(
                  width: 26,
                  height: 26,
                  icon: const Icon(LucideIcons.x, size: 13),
                  onPressed: () => _run((s) => s.remove(todo, batch: newBatchId())),
                ),
              ],
            ),
          ),
        if (fromNotes.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('노트에서 가져온 할 일 ${fromNotes.length}', style: theme.textTheme.small),
          Text('노트 본문의 "- [ ] …" 줄입니다. 끝냈으면 그 노트에서 [x]로 바꾸세요.', style: theme.textTheme.muted),
          const SizedBox(height: 6),
          for (final todo in fromNotes)
            GestureDetector(
              onTap: () => ref.read(selectedNoteProvider.notifier).select(todo.noteId),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(LucideIcons.square, size: 14, color: colors.textFaint),
                    const SizedBox(width: 10),
                    Expanded(child: Text(todo.text, style: const TextStyle(fontSize: 13))),
                    Text(todo.noteTitle ?? '', style: theme.textTheme.muted),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}
