import 'dart:math';
import 'dart:ui' as ui;

import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';

/// 뇌 그래프 (설계서 3.3·5.5). 어두운 배경 + 빛나는 노드, 추천 연결은 점선.
class GraphView extends ConsumerStatefulWidget {
  const GraphView({super.key});

  @override
  ConsumerState<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends ConsumerState<GraphView> {
  final _transform = TransformationController();
  bool _isLocal = false;
  String? _fittedKey;
  String? _hovered;

  double _lastScale = 1;

  @override
  void initState() {
    super.initState();
    // 확대할 때 글자 크기·선 굵기를 맞추려고 다시 그린다 (크게 바뀔 때만).
    _transform.addListener(() {
      final scale = _transform.value.getMaxScaleOnAxis();
      if ((scale - _lastScale).abs() / _lastScale > 0.08) {
        _lastScale = scale;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// 선택한 노트 주변 2단계까지 (로컬 그래프).
  Set<String> _neighborhood(String id, List<NoteLink> links, {int depth = 2}) {
    final seen = {id};
    var frontier = {id};
    for (var d = 0; d < depth; d++) {
      final next = <String>{};
      for (final link in links) {
        if (frontier.contains(link.fromId)) next.add(link.toId);
        if (frontier.contains(link.toId)) next.add(link.fromId);
      }
      next.removeAll(seen);
      seen.addAll(next);
      frontier = next;
    }
    return seen;
  }

  void _fit(Rect bounds, Size viewport) {
    final scale = min(
      viewport.width / max(bounds.width, 1),
      viewport.height / max(bounds.height, 1),
    ).clamp(0.05, 3.0);
    final dx = (viewport.width - bounds.width * scale) / 2 - bounds.left * scale;
    final dy = (viewport.height - bounds.height * scale) / 2 - bounds.top * scale;
    _transform.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  String? _hit(Offset world, Map<String, Point<double>> positions, double scale) {
    String? best;
    var bestDist = 14 / scale;
    for (final e in positions.entries) {
      final d = (Offset(e.value.x, e.value.y) - world).distance;
      if (d < bestDist) {
        bestDist = d;
        best = e.key;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final layout = ref.watch(graphLayoutProvider);
    final notes = ref.watch(notesProvider);
    final allLinks = ref.watch(linksProvider);
    final selected = ref.watch(selectedNoteProvider);
    final docs = {for (final d in notes) d.id: d};
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const RadialGradient(
          radius: 1.2,
          colors: [AppColors.graphTop, AppColors.graphBottom],
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: layout.when(
        loading: () => const Center(
          child: Text('그래프 배치 중…', style: TextStyle(color: AppColors.graphLabel)),
        ),
        error: (e, _) => Center(
          child: Text('그래프를 그리지 못했습니다: $e', style: const TextStyle(color: AppColors.graphLabel)),
        ),
        data: (allPositions) {
          if (allPositions.isEmpty) {
            return const Center(
              child: Text(
                '아직 노트가 없습니다. 노트가 생기면 주제별로 모여 이어집니다.',
                style: TextStyle(color: AppColors.graphLabel, fontSize: 13),
              ),
            );
          }
          final isLocal = _isLocal && selected != null && allPositions.containsKey(selected);
          final visible = isLocal
              ? _neighborhood(selected, allLinks)
              : allPositions.keys.toSet();
          final positions = {
            for (final id in visible) id: ?allPositions[id],
          };
          final links = [
            for (final l in allLinks)
              if (positions.containsKey(l.fromId) && positions.containsKey(l.toId)) l,
          ];
          final degree = <String, int>{};
          for (final l in links) {
            degree.update(l.fromId, (n) => n + 1, ifAbsent: () => 1);
            degree.update(l.toId, (n) => n + 1, ifAbsent: () => 1);
          }
          final focus = _hovered ?? selected;
          final neighbors = <String>{
            if (focus != null) ...[
              for (final l in links)
                if (l.fromId == focus) l.toId else if (l.toId == focus) l.fromId,
            ],
          };
          final xs = positions.values.map((p) => p.x);
          final ys = positions.values.map((p) => p.y);
          final bounds = Rect.fromLTRB(
            xs.reduce(min) - 80,
            ys.reduce(min) - 60,
            xs.reduce(max) + 80,
            ys.reduce(max) + 60,
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              final viewport = constraints.biggest;
              final fitKey = '${isLocal ? selected : 'all'}:${positions.length}:${viewport.width.round()}';
              if (_fittedKey != fitKey) {
                _fittedKey = fitKey;
                WidgetsBinding.instance.addPostFrameCallback((_) => _fit(Offset.zero & bounds.size, viewport));
              }
              return Stack(
                children: [
                  Positioned.fill(
                    child: InteractiveViewer(
                      transformationController: _transform,
                      constrained: false,
                      boundaryMargin: const EdgeInsets.all(double.infinity),
                      minScale: 0.05,
                      maxScale: 6,
                      child: MouseRegion(
                        onHover: (event) {
                          final scale = _transform.value.getMaxScaleOnAxis();
                          final hit = _hit(event.localPosition + bounds.topLeft, positions, scale);
                          if (hit != _hovered) setState(() => _hovered = hit);
                        },
                        onExit: (_) => setState(() => _hovered = null),
                        child: GestureDetector(
                          onTapUp: (details) {
                            final scale = _transform.value.getMaxScaleOnAxis();
                            final hit = _hit(details.localPosition + bounds.topLeft, positions, scale);
                            ref.read(selectedNoteProvider.notifier).select(hit);
                          },
                          child: CustomPaint(
                            size: bounds.size,
                            painter: _GraphPainter(
                              origin: bounds.topLeft,
                              positions: positions,
                              links: links,
                              degree: degree,
                              docs: docs,
                              focus: focus,
                              selected: selected,
                              neighbors: neighbors,
                              scale: _transform.value.getMaxScaleOnAxis(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Row(
                      children: [
                        _ModeButton(label: '전체', isOn: !isLocal, onTap: () => setState(() => _isLocal = false)),
                        const SizedBox(width: 4),
                        _ModeButton(
                          label: '이 노트 주변',
                          isOn: isLocal,
                          onTap: selected == null ? null : () => setState(() => _isLocal = true),
                        ),
                        const SizedBox(width: 4),
                        _ModeButton(label: '맞추기', isOn: false, onTap: () => _fit(Offset.zero & bounds.size, viewport)),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 12,
                    bottom: 10,
                    child: Text(
                      '노드 ${positions.length} · 연결 ${links.where((l) => !l.isSuggested).length} · 추천 ${links.where((l) => l.isSuggested).length} (점선)',
                      style: theme.textTheme.muted.copyWith(color: AppColors.graphLabel, fontSize: 11),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.label, required this.isOn, this.onTap});

  final String label;
  final bool isOn;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isOn ? const Color(0x338b5cf6) : const Color(0x14ffffff),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isOn ? const Color(0x998b5cf6) : const Color(0x22ffffff)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: onTap == null ? const Color(0x55d6d3e8) : AppColors.graphNode,
          ),
        ),
      ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.origin,
    required this.positions,
    required this.links,
    required this.degree,
    required this.docs,
    required this.focus,
    required this.selected,
    required this.neighbors,
    required this.scale,
  });

  final Offset origin;
  final Map<String, Point<double>> positions;
  final List<NoteLink> links;
  final Map<String, int> degree;
  final Map<String, IndexedDoc> docs;
  final String? focus;
  final String? selected;
  final Set<String> neighbors;
  final double scale;

  static const _accent = Color(0xff8b5cf6);

  Offset _at(String id) {
    final p = positions[id]!;
    return Offset(p.x, p.y) - origin;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 주제 이름: 주제 노드들의 가운데에 흐리게.
    final groups = <String, List<Offset>>{};
    for (final id in positions.keys) {
      final topic = docs[id]?.topic ?? '';
      groups.putIfAbsent(topic, () => []).add(_at(id));
    }
    for (final e in groups.entries) {
      if (e.value.length < 2) continue;
      final c = e.value.reduce((a, b) => a + b) / e.value.length.toDouble();
      _label(canvas, e.key, c + const Offset(0, -40), const Color(0x40d6d3e8), 13 / scale.clamp(0.6, 2), bold: true);
    }

    for (final link in links) {
      final a = _at(link.fromId);
      final b = _at(link.toId);
      final isFocus = focus != null && (link.fromId == focus || link.toId == focus);
      final paint = Paint()
        ..strokeWidth = (isFocus ? 1.6 : 0.9) / scale.clamp(0.5, 3)
        ..color = isFocus
            ? _accent.withValues(alpha: 0.9)
            : (link.isSuggested ? const Color(0x33d6d3e8) : const Color(0x66a78bfa));
      if (link.isSuggested) {
        _dashed(canvas, a, b, paint, 4 / scale.clamp(0.5, 3));
      } else {
        canvas.drawLine(a, b, paint);
      }
    }

    for (final id in positions.keys) {
      final c = _at(id);
      final d = degree[id] ?? 0;
      final r = (3.5 + sqrt(d) * 2.2).clamp(3.5, 12.0);
      final isSelected = id == selected;
      final isHot = id == focus || neighbors.contains(id);
      final isDraft = docs[id]?.isDraft ?? false;
      final color = isSelected || id == focus
          ? _accent
          : (isHot ? const Color(0xffc4b5fd) : AppColors.graphNode);
      canvas.drawCircle(
        c,
        r * 2.4,
        Paint()
          ..color = color.withValues(alpha: isHot || isSelected ? 0.28 : 0.12)
          ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 6),
      );
      canvas.drawCircle(c, r, Paint()..color = color.withValues(alpha: isDraft ? 0.55 : 0.95));
      if (isDraft) {
        canvas.drawCircle(
          c,
          r + 2,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 / scale.clamp(0.5, 3)
            ..color = const Color(0x99f59e0b),
        );
      }
      final showLabel = id == focus || isSelected || neighbors.contains(id) || d >= 3 || scale > 1.3;
      if (showLabel) {
        final title = docs[id]?.title ?? id;
        _label(
          canvas,
          title.length > 22 ? '${title.substring(0, 21)}…' : title,
          c + Offset(0, r + 9),
          isHot || isSelected ? const Color(0xffede9fe) : AppColors.graphLabel,
          11 / scale.clamp(0.6, 2.5),
        );
      }
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint, double dash) {
    final total = (b - a).distance;
    if (total == 0) return;
    final dir = (b - a) / total;
    for (var t = 0.0; t < total; t += dash * 2) {
      canvas.drawLine(a + dir * t, a + dir * min(t + dash, total), paint);
    }
  }

  void _label(Canvas canvas, String text, Offset center, Color color, double fontSize, {bool bold = false}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontFamily: 'Pretendard',
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  bool shouldRepaint(_GraphPainter old) =>
      old.positions != positions ||
      old.links != links ||
      old.focus != focus ||
      old.selected != selected ||
      old.scale != scale;
}
