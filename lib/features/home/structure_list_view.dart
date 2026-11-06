import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';
import 'graph_view.dart' show shortTitle;

/// 구조 목록 (설계서 3.3, 시안 v8 S11): 그래프를 주제 → 노트 → 연결 순서로 펼친 3칸 표.
/// | 주제 (노트 수·허브·↔ 이어진 주제) | 노트 (연결 많은 순, 같은 주제 안 연결은 들여쓰기) | 다른 주제·그 밖의 연결 (칩) |
class StructureListView extends ConsumerStatefulWidget {
  const StructureListView({super.key});

  @override
  ConsumerState<StructureListView> createState() => _StructureListViewState();
}

class _StructureListViewState extends ConsumerState<StructureListView> {
  final _collapsed = <String>{};
  String? _focusedTopic;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final notes = ref.watch(notesProvider).where((d) => !d.isMerged).toList();
    final links = ref.watch(linksProvider);
    final selected = ref.watch(selectedNoteProvider);
    final byId = {for (final d in notes) d.id: d};
    final byTopic = <String, List<IndexedDoc>>{};
    for (final d in notes) {
      byTopic.putIfAbsent(d.topic, () => []).add(d);
    }
    final pair = <String, Map<String, int>>{};
    final neighborsOf = <String, List<(String, bool)>>{};
    for (final l in links) {
      final a = byId[l.fromId], b = byId[l.toId];
      if (a == null || b == null) continue;
      neighborsOf.putIfAbsent(a.id, () => []).add((b.id, l.isSuggested));
      neighborsOf.putIfAbsent(b.id, () => []).add((a.id, l.isSuggested));
      if (a.topic == b.topic) continue;
      pair.putIfAbsent(a.topic, () => {}).update(b.topic, (n) => n + 1, ifAbsent: () => 1);
      pair.putIfAbsent(b.topic, () => {}).update(a.topic, (n) => n + 1, ifAbsent: () => 1);
    }
    final selectedNeighbors = {for (final (id, _) in neighborsOf[selected] ?? const <(String, bool)>[]) id};
    final topics = _orderTopics(byTopic, pair);
    if (topics.isEmpty) {
      return Center(child: Text('아직 노트가 없습니다.', style: theme.textTheme.muted));
    }
    Widget header(String text, {int flex = 1}) => Expanded(
      flex: flex,
      child: Text(text, style: theme.textTheme.muted.copyWith(fontSize: 12)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '그래프를 주제 → 노트 → 연결 순서로 펼쳤어요 · 같은 주제 안은 들여쓰기, 나머지는 오른쪽 칩',
                  style: theme.textTheme.muted.copyWith(fontSize: 12),
                ),
              ),
              Text('━ 직접 연결  ', style: TextStyle(fontSize: 11, color: colors.accentText)),
              Text('┄ 추천 연결', style: TextStyle(fontSize: 11, color: colors.textFaint)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(24, 6, 24, 6),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.border))),
          child: Row(children: [header('주제', flex: 3), header('노트 (연결 많은 순)', flex: 5), header('다른 주제·그 밖의 연결', flex: 4)]),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            children: [
              for (final topic in topics)
                _topicRow(topic, byTopic[topic]!, pair[topic] ?? const {}, neighborsOf, byId, selected, selectedNeighbors, colors, theme),
            ],
          ),
        ),
      ],
    );
  }

  Widget _topicRow(
    String topic,
    List<IndexedDoc> docs,
    Map<String, int> pairs,
    Map<String, List<(String, bool)>> neighborsOf,
    Map<String, IndexedDoc> byId,
    String? selected,
    Set<String> selectedNeighbors,
    AppColors colors,
    ShadThemeData theme,
  ) {
    int degree(IndexedDoc d) => (neighborsOf[d.id] ?? const []).where((n) => !n.$2).length * 10 + (neighborsOf[d.id] ?? const []).length;
    final sorted = [...docs]..sort((a, b) => degree(b).compareTo(degree(a)));
    final hub = sorted.first;
    final isCollapsed = _collapsed.contains(topic);
    final isFocused = _focusedTopic == topic;
    final pairList = pairs.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    // 같은 주제 안: 허브와 이어진 노트는 허브 아래 들여쓰기(└), 나머지는 그 아래로.
    final hubChildren = [
      for (final d in sorted.skip(1))
        if ((neighborsOf[hub.id] ?? const []).any((n) => n.$1 == d.id)) d,
    ];
    final rest = [for (final d in sorted.skip(1)) if (!hubChildren.contains(d)) d];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.border.withValues(alpha: 0.6)))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: GestureDetector(
              onTap: () => setState(() => _focusedTopic = isFocused ? null : topic),
              child: Container(
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: isFocused ? colors.accentSoft : null,
                  border: isFocused ? Border.all(color: colors.accent) : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => setState(() => isCollapsed ? _collapsed.remove(topic) : _collapsed.add(topic)),
                          child: Icon(isCollapsed ? LucideIcons.chevronRight : LucideIcons.chevronDown, size: 14, color: colors.textMuted),
                        ),
                        const SizedBox(width: 6),
                        Expanded(child: Text(topic, style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w700, color: isFocused ? colors.accentText : null))),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 20, top: 2),
                      child: Text('노트 ${docs.length} · 허브 ${shortTitle(hub.title, max: 14)}', style: theme.textTheme.muted.copyWith(fontSize: 11)),
                    ),
                    if (pairList.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 20, top: 2),
                        child: Text(
                          '↔ ${pairList.map((e) => '${e.key} ${e.value}').join(' · ')}',
                          style: TextStyle(fontSize: 11, color: isFocused ? colors.accentText : colors.textMuted),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            flex: 9,
            child: isCollapsed
                ? Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('노트 ${docs.length}개 접힘', style: theme.textTheme.muted.copyWith(fontSize: 12)),
                  )
                : Column(
                    children: [
                      _noteRow(hub, 0, neighborsOf, byId, topic, selected, selectedNeighbors, colors, theme, isHub: docs.length > 1),
                      for (final (i, d) in hubChildren.indexed)
                        _noteRow(d, 1, neighborsOf, byId, topic, selected, selectedNeighbors, colors, theme, isLast: i == hubChildren.length - 1),
                      for (final d in rest) _noteRow(d, 0, neighborsOf, byId, topic, selected, selectedNeighbors, colors, theme),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _noteRow(
    IndexedDoc doc,
    int depth,
    Map<String, List<(String, bool)>> neighborsOf,
    Map<String, IndexedDoc> byId,
    String topic,
    String? selected,
    Set<String> selectedNeighbors,
    AppColors colors,
    ShadThemeData theme, {
    bool isHub = false,
    bool isLast = false,
  }) {
    final neighbors = neighborsOf[doc.id] ?? const <(String, bool)>[];
    final outside = [
      for (final (id, isSuggested) in neighbors)
        if (byId[id] case final other? when other.topic != topic) (other, isSuggested),
    ];
    final isSelected = doc.id == selected;
    final isNeighbor = selectedNeighbors.contains(doc.id);
    final dim = _focusedTopic != null &&
        _focusedTopic != topic &&
        !neighbors.any((n) => byId[n.$1]?.topic == _focusedTopic);
    final shown = outside.take(3).toList();
    void open(String id) => ref.read(selectedNoteProvider.notifier).select(id);
    return Opacity(
      opacity: dim ? 0.35 : 1,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: GestureDetector(
                onTap: () => open(doc.id),
                child: Container(
                  margin: EdgeInsets.only(left: depth * 22.0, right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: isSelected || isHub ? colors.accentSoft : null,
                    border: isSelected ? Border.all(color: colors.accent) : null,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      if (depth > 0) Text(isLast ? '└ ' : '├ ', style: TextStyle(color: colors.textFaint, fontSize: 12)),
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: doc.isDraft ? colors.warning : (isNeighbor || isSelected ? colors.accent : colors.textFaint),
                          shape: BoxShape.circle,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          doc.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isHub ? FontWeight.w600 : FontWeight.w400,
                            color: isSelected || isNeighbor ? colors.accentText : colors.text,
                          ),
                        ),
                      ),
                      if (isHub)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: ShadBadge.secondary(child: const Text('허브')),
                        ),
                      const SizedBox(width: 6),
                      Text('${neighbors.length}', style: TextStyle(fontSize: 11, color: colors.textFaint)),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 4,
              child: Wrap(
                spacing: 4,
                runSpacing: 3,
                children: [
                  for (final (other, isSuggested) in shown)
                    GestureDetector(
                      onTap: () => open(other.id),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: isSuggested ? colors.border : colors.accent.withValues(alpha: 0.5)),
                        ),
                        child: Text(
                          '→ ${shortTitle(other.title, max: 12)}  ${other.topic}',
                          style: TextStyle(fontSize: 11, color: isSuggested ? colors.textMuted : colors.accentText),
                        ),
                      ),
                    ),
                  if (outside.length > 3) Text('+${outside.length - 3}', style: TextStyle(fontSize: 11, color: colors.textFaint)),
                  if (outside.isEmpty) Text('—', style: TextStyle(fontSize: 11, color: colors.textFaint)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 연결이 가장 많은 주제부터, 다음은 앞 주제와 가장 많이 이어진 주제를 고른다.
  List<String> _orderTopics(Map<String, List<IndexedDoc>> byTopic, Map<String, Map<String, int>> pair) {
    final left = byTopic.keys.toSet();
    final order = <String>[];
    while (left.isNotEmpty) {
      final last = order.isEmpty ? null : order.last;
      final next = left.reduce((a, b) {
        int score(String t) => last == null
            ? byTopic[t]!.length * 100 + (pair[t]?.values.fold<int>(0, (s, n) => s + n) ?? 0)
            : (pair[last]?[t] ?? 0) * 1000 + byTopic[t]!.length;
        return score(a) >= score(b) ? a : b;
      });
      order.add(next);
      left.remove(next);
    }
    return order;
  }
}
