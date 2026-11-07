import 'dart:async';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';
import '../../shared/page_header.dart';

/// 할 일 (설계서 3절 `/todos`): `todos.md` 체크리스트.
/// 추천은 두 길로 들어온다: ① AI(사용자의 Claude Code)가 노트·대화를 보고 넣은 추천
/// ② 노트에서 "남은 것·다음 할 일" 같은 줄을 찾은 후보(AI 없음). 사용자가 [받기]해야 목록에 들어간다.
class TodosPage extends ConsumerStatefulWidget {
  const TodosPage({super.key});

  @override
  ConsumerState<TodosPage> createState() => _TodosPageState();
}

class _TodosPageState extends ConsumerState<TodosPage> {
  final _input = TextEditingController();
  String? _error;
  bool _isSuggesting = false;
  String _step = '';
  Duration _elapsed = Duration.zero;
  Process? _process;

  @override
  void dispose() {
    _input.dispose();
    _process?.kill();
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

  Future<void> _onAiSuggest() async {
    final isConfirmed = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('AI로 할 일 추천 받기'),
        description: const Text(
          '이 맥의 Claude Code가 노트와 지난 대화 목록을 보고 할 일을 최대 5개 추천 칸에 넣습니다. '
          '사용자의 Claude Code 사용량(토큰)을 씁니다(보통 1분 안팎). 우리 서버는 거치지 않고, brain 명령만 쓰게 묶어 실행합니다.',
        ),
        actions: [
          ShadButton.outline(onPressed: () => Navigator.of(context).pop(false), child: const Text('취소')),
          ShadButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('동의하고 추천 받기')),
        ],
      ),
    );
    if (isConfirmed != true) return;
    final startedAt = DateTime.now();
    final timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed = DateTime.now().difference(startedAt));
    });
    setState(() {
      _isSuggesting = true;
      _step = 'Claude Code 시작 중';
      _error = null;
    });
    try {
      final result = await ref.read(claudeCodeProvider).suggestTodos(
        onStart: (p) => _process = p,
        onStep: (step) {
          if (mounted) setState(() => _step = step);
        },
      );
      if (!result.ok) {
        setState(() => _error = result.needsLogin
            ? '터미널에서 claude를 실행해 /login 한 뒤 다시 시도하세요.'
            : '추천을 받지 못했습니다: ${result.message}');
      }
    } on Object catch (e) {
      setState(() => _error = '추천을 받지 못했습니다: $e');
    } finally {
      timer.cancel();
      _process = null;
      if (mounted) setState(() => _isSuggesting = false);
      bumpVault(ref);
    }
  }

  void _onStop() => _process?.kill();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final (:todos, :suggestions) = ref.watch(todoViewProvider);
    final noteTodos = ref.watch(noteTodosProvider).value;
    final candidates = noteTodos?.candidates ?? const <Todo>[];
    final fromNotes = noteTodos?.fromNotes ?? const <Todo>[];
    final open = todos.where((t) => !t.isDone).toList();
    final done = todos.where((t) => t.isDone).toList();
    Widget sourceChip(String? id) => id == null
        ? const SizedBox()
        : GestureDetector(
            onTap: () => ref.read(selectedNoteProvider.notifier).select(id),
            child: Text('  $id', style: TextStyle(fontSize: 11, color: colors.accentText)),
          );
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
      children: [
        PageHeader(
          title: '할 일',
          subtitle: '남은 ${open.length} · 끝 ${done.length}',
          actions: [
            if (_isSuggesting)
              ShadButton.outline(size: ShadButtonSize.sm, onPressed: _onStop, child: const Text('멈추기'))
            else
              ShadButton(
                size: ShadButtonSize.sm,
                leading: const Icon(LucideIcons.sparkles, size: 14),
                onPressed: _onAiSuggest,
                child: const Text('AI로 추천 받기'),
              ),
          ],
        ),
        if (_isSuggesting) ...[
          const SizedBox(height: 10),
          const ShadProgress(),
          const SizedBox(height: 4),
          Text('$_step · ${_elapsed.inSeconds}초', style: theme.textTheme.muted),
        ],
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
        if (_error != null)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: TextStyle(color: colors.danger))),
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
                sourceChip(todo.noteId),
                ShadIconButton.ghost(
                  width: 26,
                  height: 26,
                  icon: const Icon(LucideIcons.x, size: 13),
                  onPressed: () => _run((s) => s.remove(todo, batch: newBatchId())),
                ),
              ],
            ),
          ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('AI 추천 ${suggestions.length} — 받으면 할 일에 들어갑니다', style: theme.textTheme.small),
          const SizedBox(height: 6),
          for (final todo in suggestions)
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: colors.accentSoft, borderRadius: BorderRadius.circular(6)),
              child: Row(
                children: [
                  Icon(LucideIcons.sparkles, size: 13, color: colors.accentText),
                  const SizedBox(width: 8),
                  Expanded(child: Text(todo.text, style: const TextStyle(fontSize: 13))),
                  sourceChip(todo.noteId),
                  const SizedBox(width: 8),
                  ShadButton(size: ShadButtonSize.sm, height: 26, onPressed: () => _run((s) => s.accept(todo, batch: newBatchId())), child: const Text('받기')),
                  const SizedBox(width: 4),
                  ShadButton.outline(size: ShadButtonSize.sm, height: 26, onPressed: () => _run((s) => s.remove(todo, batch: newBatchId())), child: const Text('버리기')),
                ],
              ),
            ),
        ],
        if (candidates.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('노트에서 찾은 후보 ${candidates.length}', style: theme.textTheme.small),
          Text('노트의 "남은 것·다음 할 일·확인 필요" 줄입니다 (AI 없이 찾음).', style: theme.textTheme.muted),
          const SizedBox(height: 6),
          for (final todo in candidates)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(LucideIcons.fileSearch, size: 13, color: colors.textFaint),
                  const SizedBox(width: 8),
                  Expanded(child: Text(todo.text, style: const TextStyle(fontSize: 12))),
                  Flexible(flex: 0, child: sourceChip(todo.noteId)),
                  const SizedBox(width: 6),
                  ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    height: 24,
                    onPressed: () => _run((s) => s.suggest(todo.text, source: todo.noteId, batch: newBatchId())),
                    child: const Text('추천에 넣기'),
                  ),
                ],
              ),
            ),
        ],
        if (fromNotes.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('노트 속 체크 상자 ${fromNotes.length}', style: theme.textTheme.small),
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
