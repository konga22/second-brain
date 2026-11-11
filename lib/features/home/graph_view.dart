import 'dart:math';
import 'dart:ui' as ui;

import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';

/// 그래프 맞추기 횟수 (시험용: 화면 배율을 바꿔도 다시 맞추지 않는지 본다).
@visibleForTesting
int graphFitCount = 0;

/// 성능 시험용: 그래프를 실제로 그린 횟수 (painter.paint).
int graphPaintCount = 0;

/// 뇌 그래프 (설계서 3.3·5.5). 어두운 배경 + 빛나는 노드, 추천 연결은 점선.
class GraphView extends ConsumerStatefulWidget {
  const GraphView({super.key});

  @override
  ConsumerState<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends ConsumerState<GraphView> {
  final _transform = TransformationController();
  bool _isLocal = false;
  /// 추천 연결을 그린다 (기본 켬). 끄면 고른 노드의 연결만 그린다.
  bool _showSuggested = true;

  /// 폴더(뇌) 하나만 보기. null이면 전체.
  String? _topic;
  String? _fittedKey;
  String? _hovered;

  /// 지난번 그린 영역 크기. 화면 배율·창·패널 크기가 바뀌면 그만큼 옮겨 가운데를 지킨다.
  Size? _lastViewport;

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

  /// 화면에 맞출 때 위 도구 줄(보기 전환·폴더 칩 두 줄)과 아래 범례 줄에 그래프가 가리지 않게 비워 두는 자리.
  static const _fitTop = 84.0;
  static const _fitBottom = 46.0;

  void _fit(Rect bounds, Size viewport) {
    graphFitCount++;
    // 영역이 낮으면 비워 두지 않는다 (그래프가 지나치게 작아진다).
    final hasRoom = viewport.height > 360;
    final top = hasRoom ? _fitTop : 0.0;
    final usable = viewport.height - top - (hasRoom ? _fitBottom : 0.0);
    final scale = min(
      viewport.width / max(bounds.width, 1),
      usable / max(bounds.height, 1),
    ).clamp(0.05, 3.0);
    final dx = (viewport.width - bounds.width * scale) / 2 - bounds.left * scale;
    final dy = top + (usable - bounds.height * scale) / 2 - bounds.top * scale;
    _transform.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// 영역 크기가 바뀌면 보던 가운데가 그대로 가운데에 오게 옮긴다 (다시 맞추지 않음).
  /// 같은 프레임 안에서 옮겨야 한 프레임 늦게 따라가며 튀지 않는다. 옮기기만 하고 확대 비율은
  /// 그대로라 [_transform] 리스너의 setState(확대 비율이 바뀔 때만)는 불리지 않는다.
  void _keepCenter(Size viewport) {
    final last = _lastViewport;
    if (last == null || last == viewport) return;
    final dx = (viewport.width - last.width) / 2;
    final dy = (viewport.height - last.height) / 2;
    _transform.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..multiply(_transform.value);
  }

  /// 가운데를 기준으로 확대·축소.
  void _zoomBy(double factor, Size viewport) {
    final center = Offset(viewport.width / 2, viewport.height / 2);
    _transform.value = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(factor, factor, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1)
      ..multiply(_transform.value);
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
        // 가운데가 밝은 보라빛 어둠: 노드가 빛나 보이되 너무 어둡지 않게 (11/07 가시성 의견)
        gradient: const RadialGradient(
          radius: 1.1,
          colors: [Color(0xff2b2550), Color(0xff16132a), Color(0xff0d0b18)],
          stops: [0, 0.55, 1],
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
          var visible = isLocal
              ? _neighborhood(selected, allLinks)
              : allPositions.keys.toSet();
          if (_topic != null) {
            visible = {for (final id in visible) if (docs[id]?.topic == _topic) id};
          }
          final positions = {
            for (final id in visible) id: ?allPositions[id],
          };
          final links = [
            for (final l in allLinks)
              if (positions.containsKey(l.fromId) && positions.containsKey(l.toId)) l,
          ];
          final topics = {for (final d in notes) d.topic}.toList()..sort();
          final degree = <String, int>{};
          for (final l in links) {
            if (l.isSuggested) continue; // 허브·크기는 확정 연결 기준

            degree.update(l.fromId, (n) => n + 1, ifAbsent: () => 1);
            degree.update(l.toId, (n) => n + 1, ifAbsent: () => 1);
          }
          // 바탕 그림: 확정 연결 + [추천 연결]을 켰을 때 추천 연결. 고른 노드의 연결은 위 층(_FocusPainter)이 그린다.
          final drawn = [
            for (final l in links)
              if (!l.isSuggested || _showSuggested) l,
          ];
          final focus = _hovered ?? selected;
          final focusLinks = [
            if (focus != null)
              for (final l in links)
                if (l.fromId == focus || l.toId == focus) l,
          ];
          final neighbors = <String>{
            for (final l in focusLinks) l.fromId == focus ? l.toId : l.fromId,
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
              // 맞추기는 보는 대상(전체·주변·폴더·노드 수)이 바뀔 때만 한다. 영역 크기는 넣지 않는다:
              // 화면 배율(⌘±)·창 크기가 바뀔 때마다 다시 맞추면, 앱 전체가 커진 직후 그래프가 다시
              // 줄어들어 덜덜 떨린다 (11/07 사용자 지적, 실수 노트). 크기가 바뀌면 [맞추기]로.
              // 그림 크기(노드들이 차지하는 범위)는 넣는다: 다시 배치하면 노드 수는 같아도 범위가 달라져
              // 다시 맞춰야 한다. 이것은 영역 크기와 달리 화면 배율·창 크기에 따라 바뀌지 않는다.
              final fitKey =
                  '${isLocal ? selected : 'all'}:$_topic:${positions.length}:${bounds.width.round()}x${bounds.height.round()}';
              if (_fittedKey != fitKey) {
                _fittedKey = fitKey;
                WidgetsBinding.instance.addPostFrameCallback((_) => _fit(Offset.zero & bounds.size, viewport));
              } else {
                _keepCenter(viewport);
              }
              _lastViewport = viewport;
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
                          // 끌기·확대 때 InteractiveViewer는 변환만 바꾼다. 경계로 감싸 그림을 다시 그리지 않고
                          // 이미 그린 층을 옮기게 한다 (11/07 랙 측정: 끌기 40프레임에 37번 다시 그림).
                          // 바탕(모든 노드·연결)은 데이터·확대 단계가 바뀔 때만 그린다. 마우스 올림·선택은 그래프 밖
                          // 위 층(_FocusPainter)이 그린다 (11/07 노트 1만 개 측정: 마우스를 올릴 때마다 바탕까지 다시 그려 1.4초씩 멈췄다).
                          child: RepaintBoundary(
                            child: SizedBox.fromSize(
                              size: bounds.size,
                                      child: CustomPaint(
                                        isComplex: true,
                                        painter: _GraphPainter(
                                          signature: Object.hash(
                                            identityHashCode(allPositions),
                                            identityHashCode(allLinks),
                                            identityHashCode(notes),
                                            isLocal ? selected : null,
                                            _topic,
                                            _showSuggested,
                                            _lastScale,
                                          ),
                                          origin: bounds.topLeft,
                                          positions: positions,
                                          links: drawn,
                                          degree: degree,
                                          docs: docs,
                                          scale: _lastScale,
                                        ),
                                      ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 고른 노드를 돋보이게 하는 막: 그래프 그림이 아니라 **보이는 영역 전체**를 덮는다.
                  // 그림 크기로 그리면 축소했을 때 그림보다 넓은 영역에서 막이 네모로 드러난다 (11/07 사용자 지적).
                  // 켜고 끌 때 0.15초 동안 서서히 바뀌게 해 깜빡이지 않게 한다.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: focus == null ? 0 : 1,
                        duration: const Duration(milliseconds: 150),
                        curve: Curves.easeOut,
                        child: const ColoredBox(color: Color(0x660d0b18)),
                      ),
                    ),
                  ),
                  // 위 층: 고른 노드·연결·이웃. 그래프와 같은 변환(_transform)을 적용해 그리고,
                  // 끌기·확대 때는 이 층만(노드 몇 개) 다시 그린다.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _FocusPainter(
                          transform: _transform,
                          origin: bounds.topLeft,
                          positions: positions,
                          links: focusLinks,
                          degree: degree,
                          docs: docs,
                          focus: focus,
                          selected: selected,
                          neighbors: neighbors,
                          scale: _lastScale,
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
                        const SizedBox(width: 4),
                        // 저장된 위치를 지우고 처음부터 다시 배치한다 (설계서 5.5 "꼬임 막기").
                        _ModeButton(
                          label: '다시 배치',
                          isOn: false,
                          onTap: () {
                            try {
                              ref.read(searchIndexProvider).clearGraphLayout();
                              ref.invalidate(graphLayoutProvider);
                            } on Object catch (e) {
                              ShadToaster.of(context).show(ShadToast(description: Text('다시 배치하지 못했습니다: $e')));
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  // 폴더(뇌)별로 걸러 보기
                  Positioned(
                    top: 10,
                    left: 10,
                    right: 260,
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        _ModeButton(label: '모든 폴더', isOn: _topic == null, onTap: () => setState(() => _topic = null)),
                        for (final t in topics)
                          _ModeButton(label: t, isOn: _topic == t, onTap: () => setState(() => _topic = _topic == t ? null : t)),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 12,
                    bottom: 10,
                    child: Row(
                      children: [
                        const _Legend(color: Color(0xffffffff), label: '선택한 노트', dot: true),
                        const _Legend(color: Color(0xb3c4b5fd), label: '직접 연결 [[ ]]'),
                        const _Legend(color: Color(0xb3d6d3e8), label: '추천 연결 (흐린 선은 다른 주제)', dashed: true),
                        const SizedBox(width: 8),
                        _ModeButton(
                          label: _showSuggested ? '추천 연결 숨기기' : '추천 연결 보기',
                          isOn: _showSuggested,
                          onTap: () => setState(() => _showSuggested = !_showSuggested),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '노드 ${positions.length} · 연결 ${links.where((l) => !l.isSuggested).length} · 추천 ${links.where((l) => l.isSuggested).length}',
                          style: theme.textTheme.muted.copyWith(color: AppColors.graphLabel, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: Column(
                      children: [
                        _ModeButton(label: '+', isOn: false, onTap: () => _zoomBy(1.25, viewport)),
                        const SizedBox(height: 4),
                        _ModeButton(label: '−', isOn: false, onTap: () => _zoomBy(0.8, viewport)),
                      ],
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

/// 그래프 이름표: 괄호 뒤·쌍점 뒤 설명을 빼고 10자로 줄인다.
/// "AI 실수 교정 설계: 검증 에이전트와 diff" → "AI 실수 교정 설계"
String shortTitle(String title, {int max = 10}) {
  var t = title.split(RegExp(r'[:(\[—-]')).first.trim();
  if (t.isEmpty) t = title;
  final runes = t.runes.toList();
  return runes.length <= max ? t : '${String.fromCharCodes(runes.take(max))}…';
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label, this.dot = false, this.dashed = false});

  final Color color;
  final String label;
  final bool dot;
  final bool dashed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 12),
    child: Row(
      children: [
        dot
            ? Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle))
            : Text(dashed ? '┄┄' : '──', style: TextStyle(color: color, fontSize: 11)),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: AppColors.graphLabel, fontSize: 11)),
      ],
    ),
  );
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

/// 바탕 그림: 모든 노드·연결·이름표. 데이터·확대 단계가 바뀔 때만 다시 그린다.
///
/// 노드가 많을 때(1만 개) 한 번 그리는 시간을 줄이려고 (11/07 측정 1.4초):
/// - 연결선은 모양(색·굵기·점선)별로 Path 하나에 모아 한 번에 그린다
/// - [manyNodes]를 넘으면 노드 빛 번짐·점선을 빼고, 이름표는 연결 많은 노드 [labelCap]개만
class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.signature,
    required this.origin,
    required this.positions,
    required this.links,
    required this.degree,
    required this.docs,
    required this.scale,
  });

  /// 그림에 영향을 주는 입력을 묶은 값. 같으면 다시 그리지 않는다 (지도·목록은 빌드마다 새로 만들어져 비교할 수 없음).
  final int signature;
  final Offset origin;
  final Map<String, Point<double>> positions;
  final List<NoteLink> links;
  final Map<String, int> degree;
  final Map<String, IndexedDoc> docs;
  final double scale;

  /// 노드가 이 수 이하면 이름표를 모두 단다 (적을 때는 이름이 보여야 무엇인지 안다).
  static const labelAllLimit = 60;

  /// 이보다 많으면 가벼운 그리기로 바꾼다.
  static const manyNodes = 1000;

  /// 노드가 많을 때 이름표를 다는 최대 개수 (연결 많은 순).
  static const labelCap = 150;

  @override
  void paint(Canvas canvas, Size size) {
    graphPaintCount++;
    final many = positions.length > manyNodes;
    Offset at(String id) {
      final p = positions[id]!;
      return Offset(p.x, p.y) - origin;
    }

    // 주제 이름: 주제 노드들 위쪽 끝에 흐리게.
    final groups = <String, List<Offset>>{};
    for (final id in positions.keys) {
      groups.putIfAbsent(docs[id]?.topic ?? '', () => []).add(at(id));
    }
    for (final e in groups.entries) {
      if (e.value.length < 2) continue;
      final c = e.value.reduce((a, b) => a + b) / e.value.length.toDouble();
      final top = e.value.map((o) => o.dy).reduce(min);
      _paintLabel(canvas, e.key, Offset(c.dx, top - 28), const Color(0x99c4b5fd), 14 / scale.clamp(0.6, 2), bold: true);
    }

    // 연결선: 같은 주제 안은 또렷하게, 주제를 넘는 연결은 흐리게. 모양별로 모아 한 번에 그린다.
    final paths = <(int, double, bool), Path>{};
    for (final link in links) {
      final a = at(link.fromId);
      final b = at(link.toId);
      final isSameTopic = docs[link.fromId]?.topic == docs[link.toId]?.topic;
      final color = !link.isSuggested ? 0xaaa78bfa : (isSameTopic ? 0x73d6d3e8 : 0x3dd6d3e8);
      final width = (isSameTopic ? 1.2 : 0.9) / scale.clamp(0.5, 3);
      final dashed = link.isSuggested && !many;
      final path = paths.putIfAbsent((color, width, dashed), Path.new);
      if (dashed) {
        _addDashes(path, a, b, 4 / scale.clamp(0.5, 3));
      } else {
        path
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy);
      }
    }
    for (final e in paths.entries) {
      canvas.drawPath(
        e.value,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = e.key.$2
          ..color = Color(e.key.$1),
      );
    }

    // 노드: 빛 번짐(적을 때만) → 원 → 정리 대기 테두리. 원은 진하기별로 모아 그린다.
    final solid = Path();
    final faint = Path();
    final drafts = Path();
    for (final id in positions.keys) {
      final c = at(id);
      final r = _radius(degree[id] ?? 0);
      final isDraft = docs[id]?.isDraft ?? false;
      if (!many) {
        const glow = Color(0x1fe4e1f5);
        canvas.drawCircle(
          c,
          r * 2.4,
          Paint()..shader = ui.Gradient.radial(c, r * 2.4, [glow, glow.withValues(alpha: 0)]),
        );
      }
      (isDraft ? faint : solid).addOval(Rect.fromCircle(center: c, radius: r));
      if (isDraft) drafts.addOval(Rect.fromCircle(center: c, radius: r + 2));
    }
    canvas.drawPath(solid, Paint()..color = const Color(0xf2e4e1f5));
    canvas.drawPath(faint, Paint()..color = const Color(0x8ce4e1f5));
    canvas.drawPath(
      drafts,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / scale.clamp(0.5, 3)
        ..color = const Color(0x99f59e0b),
    );

    // 이름표: 적으면 모두, 보통은 허브(확정 연결 2개 이상)·확대 시 전부, 많으면 연결 많은 순 [labelCap]개.
    final Iterable<String> labeled;
    if (positions.length <= labelAllLimit) {
      labeled = positions.keys;
    } else if (!many) {
      labeled = positions.keys.where((id) => (degree[id] ?? 0) >= 2 || scale > 1.4);
    } else {
      labeled = (positions.keys.toList()..sort((a, b) => (degree[b] ?? 0).compareTo(degree[a] ?? 0))).take(labelCap);
    }
    for (final id in labeled) {
      final c = at(id);
      _paintLabel(
        canvas,
        shortTitle(docs[id]?.title ?? id),
        c + Offset(0, _radius(degree[id] ?? 0) + 10),
        const Color(0xddeae7f7),
        12 / scale.clamp(0.6, 2.5),
        shadow: true,
      );
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) => old.signature != signature;
}

/// 위 층: 고른 노드(마우스를 올린 노드)와 그 연결·이웃만. 그래프 밖(보이는 영역)에 놓고 그래프와 같은 변환을
/// 적용해 그린다. 바탕을 다시 그리지 않으므로 노드가 많아도 가볍다.
class _FocusPainter extends CustomPainter {
  _FocusPainter({
    required this.transform,
    required this.origin,
    required this.positions,
    required this.links,
    required this.degree,
    required this.docs,
    required this.focus,
    required this.selected,
    required this.neighbors,
    required this.scale,
  }) : super(repaint: transform);

  /// 그래프 끌기·확대 변환. 이 값이 바뀌면 다시 그린다.
  final TransformationController transform;
  final Offset origin;
  final Map<String, Point<double>> positions;
  final List<NoteLink> links;
  final Map<String, int> degree;
  final Map<String, IndexedDoc> docs;
  final String? focus;
  final String? selected;
  final Set<String> neighbors;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final focus = this.focus;
    if (focus == null || !positions.containsKey(focus)) return;
    Offset at(String id) {
      final p = positions[id]!;
      return Offset(p.x, p.y) - origin;
    }

    canvas.save();
    canvas.transform(transform.value.storage);
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 / scale.clamp(0.5, 3)
      ..color = const Color(0xffa78bfa);
    for (final link in links) {
      if (!positions.containsKey(link.fromId) || !positions.containsKey(link.toId)) continue;
      final path = Path();
      if (link.isSuggested) {
        _addDashes(path, at(link.fromId), at(link.toId), 4 / scale.clamp(0.5, 3));
      } else {
        final a = at(link.fromId), b = at(link.toId);
        path
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy);
      }
      canvas.drawPath(path, edgePaint);
    }
    for (final id in {...neighbors, focus, ?selected}) {
      if (!positions.containsKey(id)) continue;
      final c = at(id);
      final r = _radius(degree[id] ?? 0);
      final isMain = id == focus || id == selected;
      final color = isMain ? const Color(0xffffffff) : const Color(0xffc4b5fd);
      final glow = color.withValues(alpha: 0.3);
      canvas.drawCircle(c, r * 2.4, Paint()..shader = ui.Gradient.radial(c, r * 2.4, [glow, glow.withValues(alpha: 0)]));
      canvas.drawCircle(c, r, Paint()..color = color);
      _paintLabel(
        canvas,
        shortTitle(docs[id]?.title ?? id),
        c + Offset(0, r + 10),
        const Color(0xffffffff),
        12 / scale.clamp(0.6, 2.5),
        shadow: true,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FocusPainter old) =>
      old.focus != focus || old.selected != selected || old.scale != scale || old.positions != positions;
}

double _radius(int degree) => (4.5 + sqrt(degree) * 2.6).clamp(4.5, 14.0);

void _addDashes(Path path, Offset a, Offset b, double dash) {
  final total = (b - a).distance;
  if (total == 0) return;
  final dir = (b - a) / total;
  for (var t = 0.0; t < total; t += dash * 2) {
    final s = a + dir * t;
    final e = a + dir * min(t + dash, total);
    path
      ..moveTo(s.dx, s.dy)
      ..lineTo(e.dx, e.dy);
  }
}

/// 이름표 글자 배치 캐시. 같은 글자·크기·색이면 다시 배치하지 않는다 (배치가 그리기에서 가장 무거움).
final _labels = <(String, double, Color, bool, bool), TextPainter>{};

void _paintLabel(Canvas canvas, String text, Offset center, Color color, double fontSize, {bool bold = false, bool shadow = false}) {
  final key = (text, (fontSize * 10).roundToDouble() / 10, color, bold, shadow);
  if (_labels.length > 600) {
    for (final p in _labels.values) {
      p.dispose();
    }
    _labels.clear();
  }
  final painter = _labels[key] ??= TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: key.$2,
        fontFamily: 'Pretendard',
        fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        shadows: shadow ? const [Shadow(color: Color(0xcc000000), blurRadius: 4)] : null,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
}
