import 'dart:math';
import 'dart:ui' as ui;

import 'package:brain_core/brain_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/background_tasks.dart';
import '../../core/brain_providers.dart';

// 신경망 보기 (설계서_프롬프트이후 5.3). 입력층(대화·가져온 문서) → 은닉층(노트) → 출력층(주제).
// 순서는 brain_core의 layoutNeural이 정하고, 여기서는 그 순서를 화면 자리로 바꿔 그린다.
// 확대·이동은 은닉층에만 적용한다 (결정 2: 대화·주제 층은 늘 화면 안).

/// 성능 시험용: 바탕을 그린 횟수와 마지막 한 번 그린 시간(마이크로초).
@visibleForTesting
int neuralPaintCount = 0;
@visibleForTesting
int neuralLastPaintMicros = 0;

/// 시험용: 그린 이름표 글자와 줄 수 (이름표를 자르지 않는지 본다, 결정 6).
@visibleForTesting
final neuralLabelLog = <({String text, int lines})>[];

/// 층 배치. 신경망 보기를 볼 때만 계산하고, 지식 폴더가 바뀌면 백그라운드에서 다시 계산하는 동안 앞 결과를 보인다.
final neuralLayoutProvider = FutureProvider.autoDispose<NeuralLayout>((ref) {
  final notes = ref.watch(notesProvider);
  final links = ref.watch(linksProvider);
  final vault = ref.watch(vaultProvider);
  return neuralLayoutInBackground(
    vault.root,
    vault.indexPath,
    [
      for (final d in notes)
        if (!d.isMerged) (id: d.id, path: d.path, title: d.title, topic: d.topic, isDraft: d.isDraft),
    ],
    // 추천 연결은 실제 관계가 아니라 뺀다 (선은 모두 실제 관계)
    [for (final l in links) if (!l.isSuggested) (l.fromId, l.toId)],
  );
});

/// [그물 | 신경망] 전환 버튼. 그래프 보기 왼쪽 위에 둔다.
class NeuralToggle extends StatelessWidget {
  const NeuralToggle({super.key, required this.isNeural, required this.onChanged});

  final bool isNeural;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: const Color(0x14ffffff),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: const Color(0x22ffffff)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Segment(label: '그물', isOn: !isNeural, onTap: () => onChanged(false)),
        _Segment(label: '신경망', isOn: isNeural, onTap: () => onChanged(true)),
      ],
    ),
  );
}

class _Segment extends StatelessWidget {
  const _Segment({required this.label, required this.isOn, required this.onTap});

  final String label;
  final bool isOn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: isOn ? const Color(0x338b5cf6) : null,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: isOn ? const Color(0x998b5cf6) : const Color(0x00000000)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.graphNode)),
    ),
  );
}

/// 그래프 보기 버튼과 같은 모양 (graph_view의 버튼은 그 파일 안에만 있어 따로 둔다).
class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x14ffffff),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0x22ffffff)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.graphNode)),
    ),
  );
}

/// 고른 것 (입력·노트·주제 중 하나, 층 안 순서 번호).
enum _Layer { input, note, topic }

typedef _Pick = ({_Layer layer, int i});

/// 신경망 보기 본체. 그래프 보기([GraphView]) 안에서 [toggle]로 바꿔 보인다.
class NeuralView extends ConsumerStatefulWidget {
  const NeuralView({super.key, required this.toggle});

  /// 왼쪽 위 [그물 | 신경망] 버튼.
  final Widget toggle;

  @override
  ConsumerState<NeuralView> createState() => _NeuralViewState();
}

class _NeuralViewState extends ConsumerState<NeuralView> with SingleTickerProviderStateMixin {
  /// 은닉층 확대 배율(1 = 층 높이에 모두 들어감)과 위아래 이동(px, 0 이하).
  double _k = 1;
  double _off = 0;

  _Pick? _hover;
  Offset? _mouse;

  /// 색인 id로 고를 수 없는 것(주제, id 없는 원본). 노트·원본 고르기는 오른쪽 패널([selectedNoteProvider])을 따른다.
  _Pick? _local;

  /// 고르면 빛이 한 번 흐른다 (대화 → 노트 → 주제, 약 1.6초).
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  final _focus = FocusNode(debugLabel: '신경망 보기');

  @override
  void dispose() {
    _pulse.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _restartPulse() {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _pulse.value = 1;
    } else {
      _pulse.forward(from: 0);
    }
  }

  /// 지금 고른 것: 주제 등 따로 고른 것이 먼저, 아니면 오른쪽 패널에 열린 노트·원본.
  _Pick? _selection(NeuralLayout layout, String? selectedId) {
    if (_local != null) return _local;
    if (selectedId == null) return null;
    final n = layout.indexOfNote(selectedId);
    if (n != null) return (layer: _Layer.note, i: n);
    final x = layout.indexOfRaw(selectedId);
    if (x != null) return (layer: _Layer.input, i: x);
    return null;
  }

  void _select(_Pick? pick, NeuralLayout layout) {
    final notifier = ref.read(selectedNoteProvider.notifier);
    final before = ref.read(selectedNoteProvider);
    String? id;
    if (pick?.layer == _Layer.note) id = layout.notes[pick!.i].id;
    if (pick?.layer == _Layer.input) id = layout.inputs[pick!.i].rawId;
    setState(() => _local = (pick == null || id != null) ? null : pick);
    if (pick == null) {
      notifier.select(null);
    } else if (id != null) {
      notifier.select(id);
    }
    // 같은 노드를 다시 누르면 패널은 그대로라 알림이 없다 → 빛만 다시 흐르게
    if (pick != null && (id == null || id == before)) _restartPulse();
  }

  void _zoomAt(double factor, double y, _Geo g) {
    final k = (_k * factor).clamp(1.0, g.kMax);
    final idx = (y - g.top - g.off) / g.s;
    setState(() {
      _k = k;
      _off = _Geo.clampOff(y - g.top - idx * g.s0 * k, g.lh, g.n * g.s0 * k);
    });
  }

  void _panBy(double dy, _Geo g) {
    setState(() => _off = _Geo.clampOff(g.off + dy, g.lh, g.n * g.s));
  }

  /// 오른쪽 패널에서 연 노트가 확대로 화면 밖이면 보이게 옮긴다 (배율은 그대로).
  void _reveal(NeuralLayout layout, String? id, Size? size) {
    if (id == null || size == null) return;
    final n = layout.indexOfNote(id);
    if (n == null) return;
    final g = _Geo(size, layout, _k, _off);
    final y = g.yNote(n);
    if (y >= g.top && y <= g.top + g.lh) return;
    setState(() => _off = _Geo.clampOff(g.lh / 2 - (n + 0.5) * g.s, g.lh, g.n * g.s));
  }

  Size? _size;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(neuralLayoutProvider);
    final selectedId = ref.watch(selectedNoteProvider);
    final layout = async.value;
    ref.listen(selectedNoteProvider, (before, next) {
      if (before == next) return;
      final current = ref.read(neuralLayoutProvider).value;
      if (_local != null) setState(() => _local = null);
      if (next != null) {
        _restartPulse();
        if (current != null) _reveal(current, next, _size);
      }
    });
    Widget message(String text) => Center(
      child: Text(text, style: const TextStyle(color: AppColors.graphLabel, fontSize: 13)),
    );
    final Widget body;
    if (layout == null) {
      body = async.hasError ? message('신경망을 그리지 못했습니다: ${async.error}') : message('신경망 배치 중…');
    } else if (layout.notes.isEmpty) {
      body = message('아직 노트가 없습니다. 노트가 생기면 대화 → 노트 → 주제로 이어집니다.');
    } else {
      body = _canvas(layout, _selection(layout, selectedId));
    }
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned(top: 10, left: 10, child: widget.toggle),
      ],
    );
  }

  Widget _canvas(NeuralLayout layout, _Pick? sel) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // 크기만 기억한다 (다시 맞추기·setState 없음 — 영역 크기에 반응해 상태를 바꾸면 떨림 고리가 생긴다, L-0005).
        // 이동값은 그릴 때 영역에 맞춰 잘라 쓴다.
        _size = size;
        final g = _Geo(size, layout, _k, _off);
        final lit = _Lit.of(layout, sel);
        return Focus(
          focusNode: _focus,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && sel != null) {
              _select(null, layout);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: Listener(
                  // 마우스 휠: 은닉층 확대. 트랙패드: 두 손가락 끌기는 이동, 벌리기는 확대 (그물 보기와 같은 손버릇)
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      _zoomAt(exp(-event.scrollDelta.dy / 300), event.localPosition.dy, g);
                    }
                  },
                  onPointerPanZoomUpdate: (event) {
                    if (event.panDelta.dy != 0) _panBy(event.panDelta.dy, g);
                    if ((event.scale - _lastScale).abs() > 0.001) {
                      _zoomAt(event.scale / _lastScale, event.localPosition.dy, g);
                      _lastScale = event.scale;
                    }
                  },
                  onPointerPanZoomStart: (_) => _lastScale = 1,
                  child: MouseRegion(
                    onHover: (event) {
                      final hit = g.hit(event.localPosition);
                      _mouse = event.localPosition;
                      if (hit != _hover) setState(() => _hover = hit);
                    },
                    onExit: (_) {
                      if (_hover != null) setState(() => _hover = null);
                    },
                    child: GestureDetector(
                      onTapUp: (details) {
                        _focus.requestFocus();
                        _select(g.hit(details.localPosition), layout);
                      },
                      onVerticalDragUpdate: (details) => _panBy(details.delta.dy, g),
                      // 바탕(모든 선·노드)은 배치·확대·이동이 바뀔 때만 그린다. 고르기·마우스 올림·빛 흐름은 위 층이 그린다.
                      child: RepaintBoundary(
                        child: CustomPaint(
                          size: size,
                          isComplex: true,
                          painter: _BasePainter(layout: layout, geo: g),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 고른 길을 돋보이게 하는 막: 보이는 영역 전체를 덮는다 (L-0007). 0.15초 동안 서서히.
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: lit == null ? 0 : 1,
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOut,
                    child: const ColoredBox(color: Color(0x990d0b18)),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _FocusPainter(
                      layout: layout,
                      geo: g,
                      lit: lit,
                      sel: sel,
                      hover: _hover,
                      pulse: _pulse,
                    ),
                  ),
                ),
              ),
              if (_hover != null && _mouse != null) _tooltip(layout, _hover!, _mouse!, size),
              Positioned(
                top: 10,
                right: 10,
                child: _ToolButton(
                  label: '맞추기',
                  onTap: () => setState(() {
                    _k = 1;
                    _off = 0;
                  }),
                ),
              ),
              Positioned(left: 12, right: 90, bottom: 10, child: _legend(layout)),
              Positioned(
                right: 10,
                bottom: 10,
                child: Column(
                  children: [
                    _ToolButton(label: '+', onTap: () => _zoomAt(1.25, g.top + g.lh / 2, g)),
                    const SizedBox(height: 4),
                    _ToolButton(label: '−', onTap: () => _zoomAt(0.8, g.top + g.lh / 2, g)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  double _lastScale = 1;

  /// 마우스를 올린 노드의 이름 전체와 종류 (이름표가 겹쳐 빠진 곳에서도 이름을 읽게).
  Widget _tooltip(NeuralLayout layout, _Pick hover, Offset at, Size size) {
    final (kind, title) = switch (hover.layer) {
      _Layer.note => (
        '노트 · ${layout.topics[layout.notes[hover.i].topic].name}${layout.notes[hover.i].isDraft ? ' · 초안' : ''}',
        layout.notes[hover.i].title,
      ),
      _Layer.input => (
        '${layout.inputs[hover.i].kind == NeuralInputKind.document ? '가져온 문서' : '대화'}'
            '${layout.inputs[hover.i].date.isEmpty ? '' : ' · ${layout.inputs[hover.i].date}'} · 노트 ${layout.inputs[hover.i].notes.length}',
        layout.inputs[hover.i].title,
      ),
      _Layer.topic => ('주제 · 노트 ${layout.topics[hover.i].count}', layout.topics[hover.i].name),
    };
    const width = 280.0;
    return Positioned(
      left: min(at.dx + 14, max(0.0, size.width - width - 8)),
      top: min(at.dy + 14, max(0.0, size.height - 80)),
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('neural-tooltip'),
          constraints: const BoxConstraints(maxWidth: width),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xf0141224),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0x33a78bfa)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(kind, style: const TextStyle(color: AppColors.graphLabel, fontSize: 11)),
              const SizedBox(height: 2),
              Text(title, style: const TextStyle(color: Color(0xffffffff), fontSize: 12.5)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legend(NeuralLayout layout) {
    Widget item(String mark, Color color, String label) => Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(mark, style: TextStyle(color: color, fontSize: 11)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: AppColors.graphLabel, fontSize: 11)),
        ],
      ),
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 4,
      children: [
        item('●', AppColors.graphNode, '대화'),
        item('◆', AppColors.graphNode, '가져온 문서'),
        item('──', const Color(0xb3d6d3e8), '속한 주제'),
        item('┄┄', const Color(0x80d6d3e8), '링크로 닿은 주제'),
        item('○', const Color(0xfff59e0b), '확인 전 초안'),
        Text(
          '대화·문서 ${layout.inputs.length} · 노트 ${layout.notes.length} · 주제 ${layout.topics.length}',
          style: const TextStyle(color: AppColors.graphLabel, fontSize: 11),
        ),
      ],
    );
  }
}

/// 화면 자리. 층 순서 번호 → y. 은닉층만 [k]배로 벌어지고 [off]만큼 움직인다.
class _Geo {
  _Geo(this.size, this.layout, this.k, double off)
    : n = layout.notes.length,
      top = size.height > 360 ? 92 : 40,
      bottom = size.height > 360 ? 48 : 12 {
    lh = max(60, size.height - top - bottom);
    xIn = (size.width * 0.2).clamp(92, 200).roundToDouble();
    xOut = (size.width - (size.width * 0.18).clamp(84, 170)).roundToDouble();
    xH = ((xIn + xOut) / 2).roundToDouble();
    s0 = lh / max(1, n);
    s = s0 * k;
    sIn = lh / max(1, layout.inputs.length);
    sOut = lh / max(1, layout.topics.length);
    this.off = clampOff(off, lh, n * s);
  }

  final Size size;
  final NeuralLayout layout;
  final double k;
  final int n;
  final double top;
  final double bottom;
  late final double lh, xIn, xOut, xH, s0, s, sIn, sOut, off;

  /// 노트 사이가 이만큼 벌어질 때까지 확대한다 (긴 제목이 두세 줄로 보일 자리).
  double get kMax => max(4, 40 / s0);

  /// 은닉층 이름표가 보이기 시작하는 간격 (시안과 같은 12px).
  static const labelGap = 12.0;
  bool get showNoteLabels => s >= labelGap;

  /// 은닉층 이름표 폭: 은닉층 → 주제 사이의 반쯤. 넘치면 줄을 바꾼다 (자르지 않음, 결정 6).
  double get noteLabelWidth => max(80, (xOut - xH) * 0.6);

  static double clampOff(double off, double lh, double contentHeight) => min(0, max(lh - contentHeight, off));

  double yIn(int i) => top + (i + 0.5) * sIn;
  double yOut(int t) => top + (t + 0.5) * sOut;
  double yNote(int i) => top + off + (i + 0.5) * s;

  /// 보이는 노트 범위 [lo, hi].
  int get lo => max(0, ((-off) / s).floor() - 1);
  int get hi => min(n - 1, ((lh - off) / s).ceil() + 1);

  /// 마우스 위치 → 노드.
  _Pick? hit(Offset at) {
    if (at.dy < top - 6 || at.dy > top + lh + 6) return null;
    int? near(int count, double Function(int) y, double spacing) {
      int? best;
      var bestD = (spacing / 2).clamp(5.0, 14.0);
      for (var i = 0; i < count; i++) {
        final d = (y(i) - at.dy).abs();
        if (d <= bestD) {
          bestD = d;
          best = i;
        }
      }
      return best;
    }

    if (at.dx >= 4 && at.dx <= xIn + 14) {
      final i = near(layout.inputs.length, yIn, sIn);
      if (i != null) return (layer: _Layer.input, i: i);
    }
    if (at.dx >= xOut - 14) {
      final t = near(layout.topics.length, yOut, sOut);
      if (t != null) return (layer: _Layer.topic, i: t);
    }
    final reach = showNoteLabels ? noteLabelWidth + 9 : 14;
    if (at.dx >= xH - 14 && at.dx <= xH + reach) {
      final p = ((at.dy - top - off) / s).floor();
      if (p >= 0 && p < n) return (layer: _Layer.note, i: p);
    }
    return null;
  }
}

/// 고른 길: 밝힐 노드와 선.
class _Lit {
  _Lit();

  final inputs = <int>{};
  final notes = <int>{};
  final topics = <int>{};

  /// 링크로 닿은 다른 주제 (반쯤 밝게, 점선).
  final faintTopics = <int>{};

  /// 입력 → 노트, 노트 → 자기 주제, 노트 → 이웃 주제(점선).
  final e1 = <(int, int)>[];
  final e2 = <(int, int)>[];
  final e3 = <(int, int)>[];

  static _Lit? of(NeuralLayout layout, _Pick? sel) {
    if (sel == null) return null;
    final lit = _Lit();
    void addNote(int i, {required bool withInputs}) {
      final n = layout.notes[i];
      lit.notes.add(i);
      if (withInputs) {
        for (final x in n.inputs) {
          lit.inputs.add(x);
          lit.e1.add((x, i));
        }
      }
      lit.topics.add(n.topic);
      lit.e2.add((i, n.topic));
    }

    switch (sel.layer) {
      case _Layer.input:
        lit.inputs.add(sel.i);
        for (final i in layout.inputs[sel.i].notes) {
          lit.e1.add((sel.i, i));
          addNote(i, withInputs: false);
        }
      case _Layer.note:
        addNote(sel.i, withInputs: true);
        for (final t in layout.notes[sel.i].neighborTopics) {
          lit.faintTopics.add(t);
          lit.e3.add((sel.i, t));
        }
      case _Layer.topic:
        lit.topics.add(sel.i);
        final t = layout.topics[sel.i];
        for (var i = t.start; i < t.start + t.count; i++) {
          addNote(i, withInputs: true);
        }
    }
    return lit;
  }
}

const _node = AppColors.graphNode; // d6d3e8
const _litNode = Color(0xffc4b5fd);
const _draft = Color(0x99f59e0b);
const _headerColor = Color(0xd9d6d3e8);

/// 노드 크기: 이어진 노트 수의 제곱근에 비례, 층이 빽빽하면 줄인다.
double _nodeRadius(int count, int maxCount, double spacing) =>
    (3 + 5 * sqrt(count / max(1, maxCount))) * max(0.4, min(1.0, spacing / 16));

/// 바탕: 층 머리말, 모든 선, 노드, (자리가 있으면) 이름표.
class _BasePainter extends CustomPainter {
  _BasePainter({required this.layout, required this.geo});

  final NeuralLayout layout;
  final _Geo geo;

  @override
  void paint(Canvas canvas, Size size) {
    final watch = Stopwatch()..start();
    neuralPaintCount++;
    final g = geo;
    final n = layout.notes.length;

    // 층 머리말
    for (final (x, a, b) in [
      (g.xIn, '입력층', '대화·문서 ${layout.inputs.length}'),
      (g.xH, '은닉층', '노트 ${layout.notes.length}'),
      (g.xOut, '출력층', '주제 ${layout.topics.length}'),
    ]) {
      _text(canvas, a, Offset(x, g.top - 30), _headerColor, 12, bold: true, align: TextAlign.center);
      _text(canvas, b, Offset(x, g.top - 15), AppColors.graphLabel, 11, align: TextAlign.center);
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, g.top - 4, size.width, g.lh + 8));

    // 선: 모양별로 Path 하나에 모아 한 번에 긋는다. 선이 많으면 옅게 (수천 개가 겹쳐 흰 덩어리가 되지 않게).
    double alpha(double base, int count) => max(0.018, min(base, base * sqrt(260 / max(1, count))));
    final e1 = Path(), e2 = Path(), e3 = Path();
    final dashed = layout.faintEdgeCount <= 2000;
    for (var i = 0; i < n; i++) {
      final note = layout.notes[i];
      final y = g.yNote(i);
      for (final x in note.inputs) {
        e1
          ..moveTo(g.xIn, g.yIn(x))
          ..lineTo(g.xH, y);
      }
      e2
        ..moveTo(g.xH, y)
        ..lineTo(g.xOut, g.yOut(note.topic));
      for (final t in note.neighborTopics) {
        _line(e3, Offset(g.xH, y), Offset(g.xOut, g.yOut(t)), dashed ? 3 : 0);
      }
    }
    Paint stroke(double a, double width) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = _node.withValues(alpha: a);
    canvas.drawPath(e1, stroke(alpha(0.34, layout.sourceEdgeCount), 1));
    canvas.drawPath(e2, stroke(alpha(0.5, n), 1.1));
    canvas.drawPath(e3, stroke(alpha(0.16, layout.faintEdgeCount), 1));
    canvas.restore();

    // 입력층·출력층: 빛나는 점. 가져온 문서는 마름모 (결정 1).
    final maxIn = layout.inputs.fold(1, (m, x) => max(m, x.notes.length));
    final maxT = layout.topics.fold(1, (m, t) => max(m, t.count));
    for (var i = 0; i < layout.inputs.length; i++) {
      final x = layout.inputs[i];
      _glowNode(canvas, Offset(g.xIn, g.yIn(i)), _nodeRadius(x.notes.length, maxIn, g.sIn), const Color(0xffe7e4f5),
          diamond: x.kind == NeuralInputKind.document);
    }
    for (var t = 0; t < layout.topics.length; t++) {
      _glowNode(canvas, Offset(g.xOut, g.yOut(t)), _nodeRadius(layout.topics[t].count, maxT, g.sOut), const Color(0xffffffff));
    }

    // 은닉층: 보이는 노트만, 칸 없이 한 줄로. 아주 빽빽하면 점 대신 짧은 막대(1만 개 → 띠).
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, g.top - 6, size.width, g.lh + 12));
    final r = (g.s * 0.34).clamp(0.7, 4.2);
    final dense = r < 1.6;
    final solid = Path(), faint = Path(), drafts = Path();
    for (var p = g.lo; p <= g.hi; p++) {
      final note = layout.notes[p];
      final y = g.yNote(p);
      final shape = dense
          ? Rect.fromCenter(center: Offset(g.xH, y), width: 3.2, height: max(1, r * 2))
          : Rect.fromCircle(center: Offset(g.xH, y), radius: r);
      if (dense) {
        (note.isDraft ? faint : solid).addRect(shape);
      } else {
        (note.isDraft ? faint : solid).addOval(shape);
      }
      // 확인 전 초안: 그물 보기와 같은 주황 테두리 (결정 3)
      if (note.isDraft) drafts.addOval(Rect.fromCircle(center: Offset(g.xH, y), radius: max(2.4, r + 1.6)));
    }
    canvas.drawPath(solid, Paint()..color = const Color(0xebe7e4f5));
    canvas.drawPath(faint, Paint()..color = const Color(0x8ce4e1f5));
    canvas.drawPath(
      drafts,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = _draft,
    );
    canvas.restore();

    // 이름표: 자리가 있을 때만. 겹치면 건너뛴다 (마우스를 올리면 위 층이 늘 단다).
    final inLabels = g.sIn >= 13;
    final topicLabels = g.sOut >= 13;
    _labelPass(canvas, [
      if (inLabels)
        for (var i = 0; i < layout.inputs.length; i++)
          _LabelItem(layout.inputs[i].title, Offset(g.xIn - 12, g.yIn(i)), max(60, g.xIn - 20), TextAlign.right),
    ]);
    _labelPass(canvas, [
      if (topicLabels)
        for (var t = 0; t < layout.topics.length; t++)
          _LabelItem('${layout.topics[t].name}  ${layout.topics[t].count}', Offset(g.xOut + 12, g.yOut(t)),
              max(60, size.width - g.xOut - 18), TextAlign.left),
    ]);
    if (g.showNoteLabels) {
      _labelPass(canvas, [
        for (var p = g.lo; p <= g.hi; p++)
          if (g.yNote(p) >= g.top - 4 && g.yNote(p) <= g.top + g.lh + 4)
            _LabelItem(layout.notes[p].title, Offset(g.xH + 9, g.yNote(p)), g.noteLabelWidth, TextAlign.left, box: true),
      ]);
    }
    neuralLastPaintMicros = watch.elapsedMicroseconds;
  }

  @override
  bool shouldRepaint(_BasePainter old) =>
      old.layout != layout || old.geo.size != geo.size || old.geo.s != geo.s || old.geo.off != geo.off;
}

/// 위 층: 고른 길·빛 흐름·마우스 올린 노드. 바탕을 다시 그리지 않아 노트가 많아도 가볍다.
class _FocusPainter extends CustomPainter {
  _FocusPainter({
    required this.layout,
    required this.geo,
    required this.lit,
    required this.sel,
    required this.hover,
    required this.pulse,
  }) : super(repaint: pulse);

  final NeuralLayout layout;
  final _Geo geo;
  final _Lit? lit;
  final _Pick? sel;
  final _Pick? hover;
  final Animation<double> pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final g = geo;
    final lit = this.lit;
    final r = (g.s * 0.34).clamp(0.7, 4.2);
    bool inView(double y) => y >= g.top - 4 && y <= g.top + g.lh + 4;
    final labels = <_LabelItem>[];
    if (lit != null) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, g.top - 4, size.width, g.lh + 8));
      double alpha(int count) => max(0.12, min(0.85, 0.85 * sqrt(60 / max(1, count))));
      final p1 = Path(), p2 = Path(), p3 = Path();
      for (final (x, i) in lit.e1) {
        p1
          ..moveTo(g.xIn, g.yIn(x))
          ..lineTo(g.xH, g.yNote(i));
      }
      for (final (i, t) in lit.e2) {
        p2
          ..moveTo(g.xH, g.yNote(i))
          ..lineTo(g.xOut, g.yOut(t));
      }
      for (final (i, t) in lit.e3) {
        _line(p3, Offset(g.xH, g.yNote(i)), Offset(g.xOut, g.yOut(t)), 3);
      }
      Paint stroke(double a, double w) => Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..color = AppColors.graphAccent.withValues(alpha: a);
      canvas.drawPath(p1, stroke(alpha(lit.e1.length), 1.4));
      canvas.drawPath(p2, stroke(alpha(lit.e2.length), 1.6));
      canvas.drawPath(p3, stroke(0.45, 1));
      _paintPulse(canvas, g, lit, pulse.value * 1600);
      canvas.restore();

      // 밝힌 노드
      final maxIn = layout.inputs.fold(1, (m, x) => max(m, x.notes.length));
      final maxT = layout.topics.fold(1, (m, t) => max(m, t.count));
      for (final i in lit.inputs) {
        _glowNode(canvas, Offset(g.xIn, g.yIn(i)), _nodeRadius(layout.inputs[i].notes.length, maxIn, g.sIn), _litNode,
            diamond: layout.inputs[i].kind == NeuralInputKind.document);
        labels.add(_LabelItem(layout.inputs[i].title, Offset(g.xIn - 12, g.yIn(i)), max(60, g.xIn - 20), TextAlign.right,
            strong: true));
      }
      for (final t in {...lit.topics, ...lit.faintTopics}) {
        final own = lit.topics.contains(t);
        _glowNode(canvas, Offset(g.xOut, g.yOut(t)), _nodeRadius(layout.topics[t].count, maxT, g.sOut),
            own ? _litNode : _litNode.withValues(alpha: 0.5));
        labels.add(_LabelItem('${layout.topics[t].name}  ${layout.topics[t].count}', Offset(g.xOut + 12, g.yOut(t)),
            max(60, size.width - g.xOut - 18), TextAlign.left,
            strong: own));
      }
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, g.top - 6, size.width, g.lh + 12));
      final dots = Path();
      for (final i in lit.notes) {
        final y = g.yNote(i);
        if (!inView(y)) continue;
        dots.addOval(Rect.fromCircle(center: Offset(g.xH, y), radius: r + 0.6));
      }
      canvas.drawPath(dots, Paint()..color = const Color(0xffddd6fe));
      canvas.restore();
      // 밝힌 노트 이름표: 확대해 자리가 있으면 보이는 것 모두, 아니면 몇 개 안 될 때만
      if (g.showNoteLabels || lit.notes.length <= 400) {
        for (final i in lit.notes) {
          final y = g.yNote(i);
          if (inView(y) && (g.showNoteLabels || lit.notes.length <= 40)) {
            labels.add(_LabelItem(layout.notes[i].title, Offset(g.xH + 9, y), g.noteLabelWidth, TextAlign.left, box: true));
          }
        }
      }
    }
    // 고른 노트·마우스 올린 노드: 빛 + 이름표는 늘 단다 (겹쳐도)
    for (final (pick, color) in [(sel, AppColors.graphAccent), (hover, const Color(0xffffffff))]) {
      if (pick == null) continue;
      switch (pick.layer) {
        case _Layer.note:
          final y = g.yNote(pick.i);
          if (!inView(y)) continue;
          _glow(canvas, Offset(g.xH, y), max(3, r + 1) * 3, color.withValues(alpha: 0.85));
          canvas.drawCircle(Offset(g.xH, y), max(2.2, r + 0.6), Paint()..color = const Color(0xffffffff));
          labels.add(_LabelItem(layout.notes[pick.i].title, Offset(g.xH + 9, y), g.noteLabelWidth, TextAlign.left,
              box: true, strong: true, force: true));
        case _Layer.input:
          labels.add(_LabelItem(layout.inputs[pick.i].title, Offset(g.xIn - 12, g.yIn(pick.i)), max(60, g.xIn - 20),
              TextAlign.right,
              box: true, strong: true, force: true));
        case _Layer.topic:
          labels.add(_LabelItem('${layout.topics[pick.i].name}  ${layout.topics[pick.i].count}',
              Offset(g.xOut + 12, g.yOut(pick.i)), max(60, size.width - g.xOut - 18), TextAlign.left,
              box: true, strong: true, force: true));
      }
    }
    // 층마다 따로 겹침을 본다 (입력·노트·주제 이름표는 x가 달라 서로 겹치지 않음)
    for (final align in [TextAlign.right, TextAlign.left]) {
      final ofLayer = labels.where((l) => l.align == align).toList();
      if (align == TextAlign.left) {
        _labelPass(canvas, ofLayer.where((l) => l.at.dx < g.xOut).toList());
        _labelPass(canvas, ofLayer.where((l) => l.at.dx >= g.xOut).toList());
      } else {
        _labelPass(canvas, ofLayer);
      }
    }
  }

  /// 빛이 한 번 흐른다: 대화 → 노트 (0~650ms), 노트 → 주제 (550~1200ms), 주제 도착 (1150~1600ms). 시안과 같은 시간.
  void _paintPulse(Canvas canvas, _Geo g, _Lit lit, double t) {
    if (t <= 0 || t >= 1600) return;
    void seg(List<(int, int)> edges, Offset Function(int) a, Offset Function(int) b, double t0, double dur) {
      final p = (t - t0) / dur;
      if (p <= 0 || p >= 1.25 || edges.isEmpty) return;
      final head = min(1.0, p), tail = max(0.0, p - 0.28);
      final step = (edges.length / 4000).ceil();
      final path = Path();
      var drawn = 0;
      final heads = <Offset>[];
      for (var j = 0; j < edges.length; j += step) {
        final (u, v) = edges[j];
        final from = a(u), to = b(v);
        final s = Offset.lerp(from, to, tail)!, e = Offset.lerp(from, to, head)!;
        path
          ..moveTo(s.dx, s.dy)
          ..lineTo(e.dx, e.dy);
        if (p < 1) heads.add(e);
        drawn++;
      }
      final a2 = max(0.05, min(0.95, sqrt(40 / drawn)));
      if (drawn <= 300) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..color = _litNode.withValues(alpha: 0.35 * a2),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = drawn <= 300 ? 1.6 : 1
          ..color = const Color(0xffffffff).withValues(alpha: a2),
      );
      if (heads.length <= 400) {
        for (final h in heads) {
          _glow(canvas, h, 9, const Color(0xffffffff));
        }
      }
    }

    seg(lit.e1, (x) => Offset(g.xIn, g.yIn(x)), (i) => Offset(g.xH, g.yNote(i)), 0, 650);
    seg(lit.e2, (i) => Offset(g.xH, g.yNote(i)), (tt) => Offset(g.xOut, g.yOut(tt)), 550, 650);
    final arrive = (t - 1150) / 450;
    if (arrive > 0 && arrive < 1) {
      for (final tt in lit.topics) {
        _glow(canvas, Offset(g.xOut, g.yOut(tt)), 10 + 26 * arrive, AppColors.graphAccent.withValues(alpha: 1 - arrive));
      }
    }
  }

  @override
  bool shouldRepaint(_FocusPainter old) =>
      old.layout != layout ||
      old.sel != sel ||
      old.hover != hover ||
      old.geo.size != geo.size ||
      old.geo.s != geo.s ||
      old.geo.off != geo.off;
}

/// 직선 (dash > 0이면 점선).
void _line(Path path, Offset a, Offset b, double dash) {
  if (dash <= 0) {
    path
      ..moveTo(a.dx, a.dy)
      ..lineTo(b.dx, b.dy);
    return;
  }
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

void _glow(Canvas canvas, Offset c, double radius, Color color) {
  canvas.drawCircle(
    c,
    radius,
    Paint()..shader = ui.Gradient.radial(c, radius, [color.withValues(alpha: color.a * 0.55), color.withValues(alpha: 0)]),
  );
}

/// 빛 번짐 + 점(또는 마름모).
void _glowNode(Canvas canvas, Offset c, double r, Color color, {bool diamond = false}) {
  _glow(canvas, c, r * 3, color.withValues(alpha: color.a * 0.6));
  final paint = Paint()..color = color;
  if (diamond) {
    canvas.drawPath(
      Path()
        ..moveTo(c.dx, c.dy - r * 1.2)
        ..lineTo(c.dx + r * 1.2, c.dy)
        ..lineTo(c.dx, c.dy + r * 1.2)
        ..lineTo(c.dx - r * 1.2, c.dy)
        ..close(),
      paint,
    );
  } else {
    canvas.drawCircle(c, r, paint);
  }
}

class _LabelItem {
  _LabelItem(this.text, this.at, this.maxWidth, this.align, {this.box = false, this.strong = false, this.force = false});

  final String text;

  /// 글 시작점(왼쪽 맞춤) 또는 끝점(오른쪽 맞춤)의 x와 노드 y.
  final Offset at;
  final double maxWidth;
  final TextAlign align;

  /// 뒤에 어두운 판을 깐다 (선 위에서도 읽히게).
  final bool box;
  final bool strong;

  /// 겹쳐도 단다 (고른 것·마우스 올린 것).
  final bool force;
}

/// 이름표를 위에서 아래로 단다. 앞 이름표와 겹치면 건너뛴다(강제는 늘 단다). 긴 제목은 줄을 바꿔 다 보인다.
void _labelPass(Canvas canvas, List<_LabelItem> items) {
  items.sort((a, b) => a.at.dy.compareTo(b.at.dy));
  var lastBottom = double.negativeInfinity;
  // 강제 이름표가 나중에 그려져 위에 오도록
  final forced = <(_LabelItem, TextPainter)>[];
  for (final it in items) {
    final painter = _painter(it.text, it.maxWidth, it.strong);
    final top = it.at.dy - painter.height / 2;
    if (it.force) {
      forced.add((it, painter));
      continue;
    }
    if (top < lastBottom + 1) continue;
    _drawLabel(canvas, it, painter);
    lastBottom = top + painter.height;
  }
  for (final (it, painter) in forced) {
    _drawLabel(canvas, it, painter);
  }
}

void _drawLabel(Canvas canvas, _LabelItem it, TextPainter painter) {
  final x = it.align == TextAlign.right ? it.at.dx - painter.width : it.at.dx;
  final topLeft = Offset(x, it.at.dy - painter.height / 2);
  if (it.box) {
    canvas.drawRRect(
      RRect.fromRectAndRadius((topLeft & painter.size).inflate(3), const Radius.circular(4)),
      Paint()..color = const Color(0xd90e0c18),
    );
  }
  painter.paint(canvas, topLeft);
  neuralLabelLog.add((text: it.text, lines: painter.computeLineMetrics().length));
  if (neuralLabelLog.length > 2000) neuralLabelLog.removeRange(0, 1000);
}

/// 이름표 글자 배치 캐시 (배치가 그리기에서 가장 무겁다). 줄 수 제한·말줄임 없이 [maxWidth]에서 줄을 바꾼다.
final _painters = <(String, int, bool), TextPainter>{};

TextPainter _painter(String text, double maxWidth, bool strong) {
  final key = (text, maxWidth.round(), strong);
  if (_painters.length > 800) {
    for (final p in _painters.values) {
      p.dispose();
    }
    _painters.clear();
  }
  return _painters[key] ??= TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: strong ? const Color(0xffffffff) : const Color(0xc7d6d3e8),
        fontSize: 11.5,
        height: 1.3,
        fontFamily: 'Pretendard',
        fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
        shadows: const [Shadow(color: Color(0xd90b0a12), blurRadius: 3)],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: key.$2.toDouble());
}

/// 층 머리말 같은 짧은 글 (가운데 맞춤).
void _text(Canvas canvas, String text, Offset center, Color color, double size, {bool bold = false, TextAlign align = TextAlign.left}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: size,
        fontFamily: 'Pretendard',
        fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
  painter.dispose();
}
