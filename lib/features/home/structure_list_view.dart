import 'dart:math';

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

  // 선(호)을 그리려고 화면에 보이는 줄의 위치를 잰다. 스크롤하면 다시 잰다.
  final _stackKey = GlobalKey();
  final _scroll = ScrollController();
  final _rowKeys = <String, GlobalKey>{};
  final _topicKeys = <String, GlobalKey>{};
  Map<String, Rect> _rects = const {};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_measure);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  GlobalKey _rowKey(String id) => _rowKeys.putIfAbsent(id, GlobalKey.new);
  GlobalKey _topicKey(String topic) =>
      _topicKeys.putIfAbsent(topic, GlobalKey.new);

  void _measure() {
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || !stack.hasSize) return;
    final rects = <String, Rect>{};
    void add(String name, GlobalKey key) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) return;
      final topLeft = box.localToGlobal(Offset.zero, ancestor: stack);
      rects[name] = topLeft & box.size;
    }

    _rowKeys.forEach((id, key) => add('n:$id', key));
    _topicKeys.forEach((topic, key) => add('t:$topic', key));
    if (!_sameRects(rects, _rects)) setState(() => _rects = rects);
  }

  static bool _sameRects(Map<String, Rect> a, Map<String, Rect> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final other = b[e.key];
      if (other == null || (other.topLeft - e.value.topLeft).distance > 0.5) {
        return false;
      }
    }
    return true;
  }

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
      pair
          .putIfAbsent(a.topic, () => {})
          .update(b.topic, (n) => n + 1, ifAbsent: () => 1);
      pair
          .putIfAbsent(b.topic, () => {})
          .update(a.topic, (n) => n + 1, ifAbsent: () => 1);
    }
    final selectedNeighbors = {
      for (final (id, _) in neighborsOf[selected] ?? const <(String, bool)>[])
        id,
    };
    final topics = _orderTopics(byTopic, pair);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measure();
    });
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
              Text(
                '━ 직접 연결  ',
                style: TextStyle(fontSize: 11, color: colors.accentText),
              ),
              Text(
                '┄ 추천 연결',
                style: TextStyle(fontSize: 11, color: colors.textFaint),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(24, 6, 24, 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.border)),
          ),
          child: Row(
            children: [
              header('주제', flex: 3),
              header('노트 (연결 많은 순)', flex: 5),
              header('다른 주제·그 밖의 연결', flex: 4),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            key: _stackKey,
            children: [
              Positioned.fill(
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(48, 4, 24, 24),
                  children: [
                    for (final topic in topics)
                      _topicRow(
                        topic,
                        byTopic[topic]!,
                        pair[topic] ?? const {},
                        neighborsOf,
                        byId,
                        selected,
                        selectedNeighbors,
                        colors,
                        theme,
                      ),
                  ],
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _ArcPainter(
                      rects: _rects,
                      selected: selected,
                      neighbors: neighborsOf[selected] ?? const [],
                      focusedTopic: _focusedTopic,
                      topicPairs: pair[_focusedTopic] ?? const {},
                      accent: colors.accent,
                      faint: colors.textFaint,
                      surface: colors.background,
                    ),
                  ),
                ),
              ),
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
    int degree(IndexedDoc d) =>
        (neighborsOf[d.id] ?? const []).where((n) => !n.$2).length * 10 +
        (neighborsOf[d.id] ?? const []).length;
    final sorted = [...docs]..sort((a, b) => degree(b).compareTo(degree(a)));
    final hub = sorted.first;
    final isCollapsed = _collapsed.contains(topic);
    final isFocused = _focusedTopic == topic;
    final pairList = pairs.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    // 같은 주제 안: 허브와 이어진 노트는 허브 아래 들여쓰기(└), 나머지는 그 아래로.
    final hubChildren = [
      for (final d in sorted.skip(1))
        if ((neighborsOf[hub.id] ?? const []).any((n) => n.$1 == d.id)) d,
    ];
    final rest = [
      for (final d in sorted.skip(1))
        if (!hubChildren.contains(d)) d,
    ];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.border.withValues(alpha: 0.6)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: GestureDetector(
              onTap: () =>
                  setState(() => _focusedTopic = isFocused ? null : topic),
              child: Container(
                key: _topicKey(topic),
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
                          onTap: () => setState(
                            () => isCollapsed
                                ? _collapsed.remove(topic)
                                : _collapsed.add(topic),
                          ),
                          child: Icon(
                            isCollapsed
                                ? LucideIcons.chevronRight
                                : LucideIcons.chevronDown,
                            size: 14,
                            color: colors.textMuted,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            topic,
                            style: theme.textTheme.small.copyWith(
                              fontWeight: FontWeight.w700,
                              color: isFocused ? colors.accentText : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 20, top: 2),
                      child: Text(
                        '노트 ${docs.length} · 허브 ${shortTitle(hub.title, max: 14)}',
                        style: theme.textTheme.muted.copyWith(fontSize: 11),
                      ),
                    ),
                    if (pairList.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 20, top: 2),
                        child: Text(
                          '↔ ${pairList.map((e) => '${e.key} ${e.value}').join(' · ')}',
                          style: TextStyle(
                            fontSize: 11,
                            color: isFocused
                                ? colors.accentText
                                : colors.textMuted,
                          ),
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
                    child: Text(
                      '노트 ${docs.length}개 접힘',
                      style: theme.textTheme.muted.copyWith(fontSize: 12),
                    ),
                  )
                : Column(
                    children: [
                      _noteRow(
                        hub,
                        0,
                        neighborsOf,
                        byId,
                        topic,
                        selected,
                        selectedNeighbors,
                        colors,
                        theme,
                        isHub: docs.length > 1,
                      ),
                      for (final (i, d) in hubChildren.indexed)
                        _noteRow(
                          d,
                          1,
                          neighborsOf,
                          byId,
                          topic,
                          selected,
                          selectedNeighbors,
                          colors,
                          theme,
                          isLast: i == hubChildren.length - 1,
                        ),
                      for (final d in rest)
                        _noteRow(
                          d,
                          0,
                          neighborsOf,
                          byId,
                          topic,
                          selected,
                          selectedNeighbors,
                          colors,
                          theme,
                        ),
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
        if (byId[id] case final other? when other.topic != topic)
          (other, isSuggested),
    ];
    final isSelected = doc.id == selected;
    final isNeighbor = selectedNeighbors.contains(doc.id);
    final dim =
        _focusedTopic != null &&
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
                  key: _rowKey(doc.id),
                  margin: EdgeInsets.only(left: depth * 22.0, right: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected || isHub ? colors.accentSoft : null,
                    border: isSelected
                        ? Border.all(color: colors.accent)
                        : null,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      if (depth > 0)
                        Text(
                          isLast ? '└ ' : '├ ',
                          style: TextStyle(
                            color: colors.textFaint,
                            fontSize: 12,
                          ),
                        ),
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: doc.isDraft
                              ? colors.warning
                              : (isNeighbor || isSelected
                                    ? colors.accent
                                    : colors.textFaint),
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
                            fontWeight: isHub
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: isSelected || isNeighbor
                                ? colors.accentText
                                : colors.text,
                          ),
                        ),
                      ),
                      if (isHub)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: ShadBadge.secondary(child: const Text('허브')),
                        ),
                      const SizedBox(width: 6),
                      Text(
                        '${neighbors.length}',
                        style: TextStyle(fontSize: 11, color: colors.textFaint),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 4,
              // 왼쪽 34px는 고른 노트의 연결 호가 지나가는 자리
              child: Padding(
                padding: const EdgeInsets.only(left: 34),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 3,
                  children: [
                    for (final (other, isSuggested) in shown)
                      GestureDetector(
                        onTap: () => open(other.id),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: isSuggested
                                  ? colors.border
                                  : colors.accent.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Text(
                            '→ ${shortTitle(other.title, max: 12)}  ${other.topic}',
                            style: TextStyle(
                              fontSize: 11,
                              color: isSuggested
                                  ? colors.textMuted
                                  : colors.accentText,
                            ),
                          ),
                        ),
                      ),
                    if (outside.length > 3)
                      Text(
                        '+${outside.length - 3}',
                        style: TextStyle(fontSize: 11, color: colors.textFaint),
                      ),
                    if (outside.isEmpty)
                      Text(
                        '—',
                        style: TextStyle(fontSize: 11, color: colors.textFaint),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 연결이 가장 많은 주제부터, 다음은 앞 주제와 가장 많이 이어진 주제를 고른다.
  List<String> _orderTopics(
    Map<String, List<IndexedDoc>> byTopic,
    Map<String, Map<String, int>> pair,
  ) {
    final left = byTopic.keys.toSet();
    final order = <String>[];
    while (left.isNotEmpty) {
      final last = order.isEmpty ? null : order.last;
      final next = left.reduce((a, b) {
        int score(String t) => last == null
            ? byTopic[t]!.length * 100 +
                  (pair[t]?.values.fold<int>(0, (s, n) => s + n) ?? 0)
            : (pair[last]?[t] ?? 0) * 1000 + byTopic[t]!.length;
        return score(a) >= score(b) ? a : b;
      });
      order.add(next);
      left.remove(next);
    }
    return order;
  }
}

/// 구조 목록의 선 (시안 v8): 노트를 고르면 오른쪽에 그 노트에서 이웃 노트까지 호(추천은 점선),
/// 주제를 누르면 왼쪽에 이어진 주제까지 굵은 호와 연결 수.
class _ArcPainter extends CustomPainter {
  _ArcPainter({
    required this.rects,
    required this.selected,
    required this.neighbors,
    required this.focusedTopic,
    required this.topicPairs,
    required this.accent,
    required this.faint,
    required this.surface,
  });

  final Map<String, Rect> rects;
  final String? selected;
  final List<(String, bool)> neighbors;
  final String? focusedTopic;
  final Map<String, int> topicPairs;
  final Color accent;
  final Color faint;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    final from = rects['n:$selected'];
    if (from != null) {
      final x = from.right;
      final start = Offset(x, from.center.dy);
      for (final (id, isSuggested) in neighbors) {
        final to = rects['n:$id'];
        if (to == null) continue;
        final end = Offset(to.right, to.center.dy);
        final bulge = 18 + min(90.0, (end.dy - start.dy).abs() * 0.18);
        final path = Path()
          ..moveTo(start.dx, start.dy)
          ..cubicTo(x + bulge, start.dy, x + bulge, end.dy, end.dx, end.dy);
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = isSuggested ? 1.3 : 1.8
          ..color = accent.withValues(alpha: isSuggested ? 0.7 : 0.95);
        isSuggested
            ? _dashedPath(canvas, path, paint)
            : canvas.drawPath(path, paint);
        canvas.drawCircle(end, 2.5, Paint()..color = accent);
      }
      canvas.drawCircle(start, 3, Paint()..color = accent);
    }
    final topic = rects['t:$focusedTopic'];
    if (topic != null) {
      final start = Offset(topic.left - 4, topic.top + 14);
      for (final e in topicPairs.entries) {
        final to = rects['t:${e.key}'];
        if (to == null) continue;
        final end = Offset(to.left - 4, to.top + 14);
        final bulge = 14 + min(26.0, (end.dy - start.dy).abs() * 0.05);
        final path = Path()
          ..moveTo(start.dx, start.dy)
          ..cubicTo(
            start.dx - bulge,
            start.dy,
            end.dx - bulge,
            end.dy,
            end.dx,
            end.dy,
          );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 + min(4, e.value.toDouble())
            ..color = accent.withValues(alpha: 0.75),
        );
        // 호 가운데에 연결 수 원
        final mid = Offset(start.dx - bulge * 0.75, (start.dy + end.dy) / 2);
        canvas.drawCircle(mid, 9, Paint()..color = accent);
        final label = TextPainter(
          text: TextSpan(
            text: '${e.value}',
            style: const TextStyle(
              color: Color(0xffffffff),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, mid - Offset(label.width / 2, label.height / 2));
      }
    }
  }

  void _dashedPath(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 8) {
        canvas.drawPath(
          metric.extractPath(d, min(d + 4, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.rects != rects ||
      old.selected != selected ||
      old.focusedTopic != focusedTopic ||
      old.neighbors != neighbors;
}
