import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../app/router/app_page.dart';
import '../app/theme/app_colors.dart';
import '../core/brain_providers.dart';
import '../features/connect/claude_code_providers.dart';
import '../features/connect/system_check_provider.dart';
import 'command_palette.dart';

class Sidebar extends ConsumerWidget {
  const Sidebar({super.key, required this.current});

  final AppPage current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final theme = ShadTheme.of(context);
    // 앱을 켜면 바로 점검하고, 문제가 있으면 연동 옆에 점을 붙인다.
    final hasProblem = ref.watch(
      systemCheckProvider.select(
        (check) => switch (check) {
          AsyncData(:final value) => value.hasProblem,
          AsyncError() => true,
          _ => false,
        },
      ),
    );
    final notes = ref.watch(notesProvider);
    final pendingLessons = ref
        .watch(lessonsProvider)
        .where((l) => l.status == LessonStatus.pending)
        .length;
    final openTodos = ref
        .watch(todoStoreProvider)
        .list()
        .where((t) => !t.isDone)
        .length;
    final counts = {
      AppPage.notes: '${notes.length}',
      if (pendingLessons > 0) AppPage.lessons: '$pendingLessons',
      if (openTodos > 0) AppPage.todos: '$openTodos',
    };
    final vault = ref.watch(vaultProvider);
    final claude = ref.watch(claudeCodeStatusProvider).value;
    return Container(
      width: 232,
      decoration: BoxDecoration(
        color: colors.sidebar,
        border: Border(right: BorderSide(color: colors.border)),
      ),
      // 위쪽 28은 macOS 창 신호등 버튼 자리
      padding: const EdgeInsets.fromLTRB(10, 28, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
            child: Text('세컨드 브레인', style: theme.textTheme.large),
          ),
          GestureDetector(
            onTap: () => showCommandPalette(context),
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border.all(color: colors.border),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.search, size: 14, color: colors.textFaint),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '찾기·명령',
                      style: TextStyle(fontSize: 13, color: colors.textFaint),
                    ),
                  ),
                  Text(
                    '⌘K',
                    style: TextStyle(fontSize: 11, color: colors.textFaint),
                  ),
                ],
              ),
            ),
          ),
          for (final page in AppPage.values)
            _SidebarItem(
              page: page,
              isSelected: page == current,
              hasProblem: page == AppPage.connect && hasProblem,
              count: counts[page],
            ),
          const SizedBox(height: 12),
          const Expanded(child: _TopicTree()),
          Container(
            height: 1,
            color: colors.border,
            margin: const EdgeInsets.symmetric(vertical: 6),
          ),
          _StatusLine(
            color: claude == null
                ? colors.textFaint
                : (claude.isInstalled && claude.isEnabled
                      ? colors.success
                      : colors.warning),
            text: claude == null
                ? 'Claude Code 확인 중'
                : (claude.isInstalled ? 'Claude Code 연결됨' : 'Claude Code 연동 전'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
            child: Text(
              '${vault.root.replaceFirst(Platform.environment['HOME'] ?? '~', '~')} · 노트 ${notes.length}개'
              '${ref.watch(indexingProvider) ? ' · 색인 중…' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.textFaint),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    child: Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: AppColors.of(context).textMuted,
          ),
        ),
      ],
    ),
  );
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.page,
    required this.isSelected,
    required this.hasProblem,
    this.count,
  });

  final AppPage page;
  final bool isSelected;
  final bool hasProblem;
  final String? count;

  void _onTap(BuildContext context) => context.go(page.path);

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final color = isSelected ? colors.accentText : colors.textMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _onTap(context),
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: isSelected ? colors.accentSoft : null,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                Icon(page.icon, size: 16, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    page.label,
                    style: TextStyle(fontSize: 14, color: color),
                  ),
                ),
                if (hasProblem)
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: colors.warning,
                      shape: BoxShape.circle,
                    ),
                  )
                else if (count != null)
                  Text(
                    count!,
                    style: TextStyle(fontSize: 11, color: colors.textFaint),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 사이드바 주제·파일 (설계서 3.2): 지식 폴더 구조 그대로.
/// - 폴더를 누르면 접고 다시 누르면 편다. 고른 노트의 폴더는 접어도 보라 표시가 남는다.
/// - 노트를 끌어 다른 폴더에 놓으면 그 폴더로 옮긴다 (id·[[링크]] 유지).
/// - [+]로 폴더(뇌)를 만들고, [추천 정리]는 연결의 다수가 다른 폴더에 있는 노트를 옮기자고 제안한다.
class _TopicTree extends ConsumerStatefulWidget {
  const _TopicTree();

  @override
  ConsumerState<_TopicTree> createState() => _TopicTreeState();
}

class _TopicTreeState extends ConsumerState<_TopicTree> {
  static const rawTopic = '원본 (raw)';
  final _open = <String>{};
  String? _dropHover;

  void _onToggle(String topic) => setState(
    () => _open.contains(topic) ? _open.remove(topic) : _open.add(topic),
  );

  void _onMove(String noteId, String topic) {
    try {
      ref.read(noteStoreProvider).move(noteId, topic);
      _open.add(topic);
      bumpVault(ref);
    } on NoteStoreException catch (e) {
      ShadToaster.maybeOf(context)
          ?.show(ShadToast.destructive(description: Text(e.message)));
    }
  }

  Future<void> _onAddTopic() async {
    final controller = TextEditingController();
    final name = await showShadDialog<String>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('폴더 추가'),
        description: const Text(
          '주제 폴더는 하나의 "뇌"입니다. 노트를 끌어다 놓아 정리하고, AI 질문에서 이 폴더 지식으로만 답하게 할 수 있습니다.',
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('만들기'),
          ),
        ],
        child: ShadInput(
          controller: controller,
          autofocus: true,
          placeholder: const Text('폴더 이름 (예: 대학교)'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final topic = ref.read(noteStoreProvider).createTopic(name);
    setState(() => _open.add(topic));
    bumpVault(ref);
  }

  Future<void> _onSuggest() async {
    final store = ref.read(noteStoreProvider);
    final index = ref.read(searchIndexProvider);
    final moves = store.suggestMoves();
    await showShadDialog<void>(
      context: context,
      builder: (context) => _SuggestDialog(
        moves: [
          for (final (id, from, to, count) in moves)
            (id, index.byId(id)?.title ?? id, from, to, count),
        ],
        onMove: (id, to) => _onMove(id, to),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final notes = ref.watch(notesProvider);
    final raw = ref.watch(rawDocsProvider);
    final selected = ref.watch(selectedNoteProvider);
    ref.watch(vaultRevisionProvider);
    final issues = {
      for (final i in ref.watch(lintIssuesProvider).value ?? const <LintIssue>[])
        if (i.type != LintType.orphan) i.id,
    };
    final byTopic = <String, List<IndexedDoc>>{
      for (final t in ref.watch(searchIndexProvider).topics()) t: [],
    };
    for (final d in notes) {
      byTopic.putIfAbsent(d.topic, () => []).add(d);
    }
    final topics = byTopic.keys.toList()..sort();
    if (raw.isNotEmpty) {
      byTopic[rawTopic] = raw;
      topics.add(rawTopic);
    }
    final activeTopic = [
      for (final t in topics)
        if (byTopic[t]!.any((d) => d.id == selected)) t,
    ].firstOrNull;
    // 노트를 새로 고르면 그 폴더를 펼친다 (사용자가 접으면 접힌 채로 둔다).
    ref.listen(selectedNoteProvider, (previous, next) {
      if (next == null || next == previous) return;
      for (final t in byTopic.keys) {
        if (byTopic[t]!.any((d) => d.id == next)) setState(() => _open.add(t));
      }
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '주제·파일',
                style: TextStyle(fontSize: 11, color: colors.textFaint),
              ),
            ),
            _MiniButton(
              icon: LucideIcons.wandSparkles,
              tooltip: '추천 정리',
              onTap: _onSuggest,
            ),
            _MiniButton(
              icon: LucideIcons.folderPlus,
              tooltip: '폴더 추가',
              onTap: _onAddTopic,
            ),
            _MiniButton(
              icon: LucideIcons.folderOpen,
              tooltip: 'Finder에서 열기',
              onTap: () =>
                  Process.run('open', [ref.read(vaultProvider).wikiDir]),
            ),
          ],
        ),
        // E4 충돌 사본 알림 (설계서 3.0)
        if (ref.watch(conflictCountProvider) case final conflicts when conflicts > 0)
          ShadButton.ghost(
            size: ShadButtonSize.sm,
            leading: const Icon(LucideIcons.triangleAlert, size: 14),
            onPressed: () => Process.run('open', [p.join(ref.read(vaultProvider).metaDir, 'conflicts')]),
            child: Text('충돌 사본 $conflicts개 — Finder에서 비교'),
          ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              for (final topic in topics) ...[
                DragTarget<String>(
                  onWillAcceptWithDetails: (d) {
                    if (topic == rawTopic) return false;
                    setState(() => _dropHover = topic);
                    return true;
                  },
                  onLeave: (_) => setState(() => _dropHover = null),
                  onAcceptWithDetails: (d) {
                    setState(() => _dropHover = null);
                    _onMove(d.data, topic);
                  },
                  builder: (context, _, _) {
                    final isOpen = _open.contains(topic);
                    final isActive = topic == activeTopic;
                    return GestureDetector(
                      onTap: () => _onToggle(topic),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _dropHover == topic ? colors.accentSoft : null,
                          border: _dropHover == topic
                              ? Border.all(color: colors.accent)
                              : null,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isOpen
                                  ? LucideIcons.chevronDown
                                  : LucideIcons.chevronRight,
                              size: 12,
                              color: colors.textFaint,
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              isOpen
                                  ? LucideIcons.folderOpen
                                  : LucideIcons.folder,
                              size: 14,
                              color: isActive
                                  ? colors.accentText
                                  : colors.textMuted,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                topic,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isActive
                                      ? colors.accentText
                                      : colors.textMuted,
                                  fontWeight: isActive
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            if (isActive && !isOpen)
                              Container(
                                width: 6,
                                height: 6,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                  color: colors.accent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            Text(
                              '${byTopic[topic]!.length}',
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.textFaint,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                if (_open.contains(topic))
                  for (final doc in byTopic[topic]!)
                    _FileRow(
                      doc: doc,
                      isSelected: doc.id == selected,
                      hasIssue: issues.contains(doc.id),
                      isDraggable: topic != rawTopic,
                      onTap: () => ref
                          .read(selectedNoteProvider.notifier)
                          .select(doc.id),
                    ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.doc,
    required this.isSelected,
    required this.hasIssue,
    required this.isDraggable,
    required this.onTap,
  });

  final IndexedDoc doc;
  final bool isSelected;
  final bool hasIssue;
  final bool isDraggable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final row = GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(left: 22),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected ? colors.accentSoft : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${doc.title}.md',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: isSelected ? colors.accentText : colors.text,
                ),
              ),
            ),
            if (hasIssue)
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: colors.warning,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
    if (!isDraggable) return row;
    return Draggable<String>(
      data: doc.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.accent),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          doc.title,
          style: TextStyle(
            fontSize: 12,
            color: colors.text,
            decoration: TextDecoration.none,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      child: row,
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ShadTooltip(
    builder: (_) => Text(tooltip),
    child: ShadIconButton.ghost(
      width: 24,
      height: 24,
      icon: Icon(icon, size: 13, color: AppColors.of(context).textMuted),
      onPressed: onTap,
    ),
  );
}

/// 추천 정리 결과: 노트마다 [옮기기]. 옮기면 그 줄은 사라진다.
class _SuggestDialog extends StatefulWidget {
  const _SuggestDialog({required this.moves, required this.onMove});

  final List<(String, String, String, String, int)> moves;
  final void Function(String id, String to) onMove;

  @override
  State<_SuggestDialog> createState() => _SuggestDialogState();
}

class _SuggestDialogState extends State<_SuggestDialog> {
  final _done = <String>{};

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final left = [
      for (final m in widget.moves)
        if (!_done.contains(m.$1)) m,
    ];
    return ShadDialog(
      title: const Text('추천 정리'),
      description: const Text(
        '연결된 노트의 다수가 다른 폴더에 있으면 그 폴더로 옮기자고 제안합니다. 옮겨도 [[링크]]는 그대로이고, brain undo로 되돌릴 수 있습니다.',
      ),
      constraints: const BoxConstraints(maxWidth: 620),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
      child: left.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('지금은 옮길 만한 노트가 없습니다.', style: theme.textTheme.muted),
            )
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (id, title, from, to, count) in left)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: theme.textTheme.small),
                                Text(
                                  '$from → $to (연결 $count개가 $to에 있음)',
                                  style: theme.textTheme.muted,
                                ),
                              ],
                            ),
                          ),
                          ShadButton.outline(
                            size: ShadButtonSize.sm,
                            onPressed: () {
                              widget.onMove(id, to);
                              setState(() => _done.add(id));
                            },
                            child: const Text('옮기기'),
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
