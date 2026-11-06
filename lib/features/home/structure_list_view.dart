import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';

/// 구조 목록 (설계서 3.3): 주제 → 노트 → 연결. 주제끼리 연결 수는 `↔ 주제 N`으로,
/// 노트의 연결은 오른쪽 칩으로(추천은 반투명, 3개 넘으면 +N). 주제는 접고 펼친다.
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
    // 주제 쌍 연결 수 → 연결이 많은 주제끼리 가깝게 놓는다.
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
    final topics = _orderTopics(byTopic, pair);
    if (topics.isEmpty) {
      return Center(child: Text('아직 노트가 없습니다.', style: theme.textTheme.muted));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        for (final topic in topics) ...[
          GestureDetector(
            onTap: () => setState(() => _focusedTopic = _focusedTopic == topic ? null : topic),
            child: Container(
              margin: const EdgeInsets.only(top: 14, bottom: 4),
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    width: 3,
                    color: _focusedTopic == topic ? colors.accent : colors.borderStrong,
                  ),
                ),
              ),
              child: Row(
                children: [
                  ShadIconButton.ghost(
                    width: 24,
                    height: 24,
                    icon: Icon(
                      _collapsed.contains(topic) ? LucideIcons.chevronRight : LucideIcons.chevronDown,
                      size: 14,
                    ),
                    onPressed: () => setState(
                      () => _collapsed.contains(topic) ? _collapsed.remove(topic) : _collapsed.add(topic),
                    ),
                  ),
                  Text('{ $topic', style: theme.textTheme.small),
                  const SizedBox(width: 8),
                  Text('노트 ${byTopic[topic]!.length}', style: theme.textTheme.muted),
                  const SizedBox(width: 12),
                  for (final e in (pair[topic]?.entries.toList() ?? [])..sort((a, b) => b.value.compareTo(a.value)))
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        '↔ ${e.key} ${e.value}',
                        style: theme.textTheme.muted.copyWith(
                          color: _focusedTopic == topic || _focusedTopic == e.key ? colors.accentText : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!_collapsed.contains(topic))
            for (final doc in byTopic[topic]!..sort((a, b) => a.title.compareTo(b.title)))
              _NoteLine(
                doc: doc,
                neighbors: [
                  for (final (id, isSuggested) in neighborsOf[doc.id] ?? const <(String, bool)>[])
                    if (byId[id] case final other?) (other, isSuggested),
                ],
                isSelected: doc.id == selected,
                isDimmed: _focusedTopic != null &&
                    _focusedTopic != topic &&
                    !(neighborsOf[doc.id] ?? []).any((n) => byId[n.$1]?.topic == _focusedTopic),
                onOpen: (id) => ref.read(selectedNoteProvider.notifier).select(id),
              ),
        ],
      ],
    );
  }

  /// 연결이 가장 많은 주제부터, 다음은 앞 주제와 가장 많이 이어진 주제를 고르는 식으로 줄 세운다.
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

class _NoteLine extends StatelessWidget {
  const _NoteLine({
    required this.doc,
    required this.neighbors,
    required this.isSelected,
    required this.isDimmed,
    required this.onOpen,
  });

  final IndexedDoc doc;
  final List<(IndexedDoc, bool)> neighbors;
  final bool isSelected;
  final bool isDimmed;
  final void Function(String id) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final shown = neighbors.take(3).toList();
    return Opacity(
      opacity: isDimmed ? 0.35 : 1,
      child: GestureDetector(
        onTap: () => onOpen(doc.id),
        child: Container(
          margin: const EdgeInsets.only(left: 26, bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? colors.accentSoft : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Text('├─ ', style: theme.textTheme.muted),
              if (doc.isDraft)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(LucideIcons.fileClock, size: 13, color: colors.warning),
                ),
              Flexible(
                child: Text(
                  doc.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: isSelected ? colors.accentText : colors.text),
                ),
              ),
              const SizedBox(width: 10),
              for (final (other, isSuggested) in shown)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: GestureDetector(
                    onTap: () => onOpen(other.id),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSuggested ? colors.border : colors.accent.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        other.title.length > 12 ? '${other.title.substring(0, 11)}…' : other.title,
                        style: TextStyle(
                          fontSize: 11,
                          color: isSuggested ? colors.textFaint : colors.accentText,
                        ),
                      ),
                    ),
                  ),
                ),
              if (neighbors.length > 3) Text('+${neighbors.length - 3}', style: theme.textTheme.muted),
            ],
          ),
        ),
      ),
    );
  }
}
