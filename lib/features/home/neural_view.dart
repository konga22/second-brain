import 'dart:math';
import 'dart:ui' as ui;

import 'package:brain_core/brain_core.dart';
import 'package:flutter/foundation.dart';
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

// 아래 시험용 값은 릴리스 빌드에서는 세지 않는다 (kReleaseMode는 상수라 릴리스에서는 코드가 빠진다, 11/13 검토 7).

/// 성능 시험용: 바탕을 그린 횟수와 마지막 한 번 그린 시간(마이크로초).
@visibleForTesting
int neuralPaintCount = 0;
@visibleForTesting
int neuralLastPaintMicros = 0;

/// 시험용: 그린 이름표 글자·줄 수·글자 자리·밝힘 (이름표를 자르지 않는지, 고른 길 이름표가 겹치지 않는지 본다, 결정 6).
@visibleForTesting
final neuralLabelLog = <({String text, int lines, Rect rect, bool strong})>[];

/// 시험용: 고른 길 층(정지 그림)을 그린 횟수. 빛이 흐르는 동안에는 늘지 않아야 한다 (11/13 검토 3).
@visibleForTesting
int neuralPathPaintCount = 0;

/// 시험용: 빛 흐름을 그린 프레임 수와, 한 프레임에 그은 선·빛 번짐 수의 최댓값.
@visibleForTesting
int neuralPulseFrames = 0;
@visibleForTesting
int neuralPulseMaxLines = 0;
@visibleForTesting
int neuralPulseMaxGlows = 0;

/// 이름표 글자 배치 캐시 크기. 넘치면 다음 그리기를 시작할 때 오래 안 쓴 것부터 버린다.
@visibleForTesting
int neuralPainterCacheLimit = 800;

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
        // 주제는 구역/주제 경로로 묶는다: 같은 이름 주제가 다른 구역에 있을 수 있다 (5.1, 그물 보기와 같음)
        if (!d.isMerged) (id: d.id, path: d.path, title: d.title, topic: d.topicPath, isDraft: d.isDraft),
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

/// 층 이름.
enum _Layer { input, note, topic }

/// 지금 배치에서의 자리 (층 안 순서 번호). 배치가 바뀌면 번호가 바뀌므로 그 빌드 안에서만 쓴다.
typedef _At = ({_Layer layer, int i});

/// 고른 것·마우스 올린 것을 기억하는 이름: 노트 id, 원본 경로, 주제 이름.
/// 순서 번호로 기억하면 CLI·AI 저장·합치기·지우기로 배치가 다시 계산될 때 없는 번호를 읽어 터지거나(RangeError)
/// 다른 노드가 밝아졌다. 빌드마다 새 배치에서 다시 찾고, 없으면 버린다 (설계서_프롬프트이후 5.3, 11/13 검토 1).
typedef _Key = ({_Layer layer, String key});

_Key _keyOf(NeuralLayout layout, _At at) => (
  layer: at.layer,
  key: switch (at.layer) {
    _Layer.input => layout.inputs[at.i].path,
    _Layer.note => layout.notes[at.i].id,
    _Layer.topic => layout.topics[at.i].name,
  },
);

_At? _find(NeuralLayout layout, _Key? k) {
  if (k == null) return null;
  final i = switch (k.layer) {
    _Layer.input => layout.indexOfInput(k.key),
    _Layer.note => layout.indexOfNote(k.key),
    _Layer.topic => layout.indexOfTopic(k.key),
  };
  return i == null ? null : (layer: k.layer, i: i);
}

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

  _Key? _hover;

  /// 마우스 자리. 안내 상자만 따라 움직이게 따로 둔다 (마우스가 같은 노드 위에서 움직여도 상자가 따라온다, 11/13 검토 7).
  final _mouse = ValueNotifier<Offset?>(null);

  /// 색인 id로 고를 수 없는 것(주제, id 없는 원본). 노트·원본 고르기는 오른쪽 패널([selectedNoteProvider])을 따른다.
  _Key? _local;

  /// 고른 길에서 미리 계산한 것 (배치·고른 것·자리가 같으면 다시 쓴다).
  _Prepared? _prepared;

  /// 고르면 빛이 한 번 흐른다 (대화 → 노트 → 주제, 약 1.6초).
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  final _focus = FocusNode(debugLabel: '신경망 보기');

  @override
  void dispose() {
    _pulse.dispose();
    _focus.dispose();
    _mouse.dispose();
    _prepared?.dispose();
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
  _At? _selection(NeuralLayout layout, String? selectedId) {
    if (_local != null) {
      final at = _find(layout, _local);
      if (at != null) return at;
      // 다시 계산한 배치에 없다 (주제가 없어짐 등). 빌드 중이라 setState 없이 버린다 — 보이는 것은 같다.
      _local = null;
    }
    if (selectedId == null) return null;
    final n = layout.indexOfNote(selectedId);
    if (n != null) return (layer: _Layer.note, i: n);
    final x = layout.indexOfRaw(selectedId);
    if (x != null) return (layer: _Layer.input, i: x);
    return null;
  }

  void _select(_At? pick, NeuralLayout layout) {
    final notifier = ref.read(selectedNoteProvider.notifier);
    final before = ref.read(selectedNoteProvider);
    String? id;
    if (pick?.layer == _Layer.note) id = layout.notes[pick!.i].id;
    if (pick?.layer == _Layer.input) id = layout.inputs[pick!.i].rawId;
    setState(() => _local = (pick == null || id != null) ? null : _keyOf(layout, pick));
    if (pick == null) {
      notifier.select(null);
    } else if (id != null) {
      notifier.select(id);
    }
    // 같은 노드를 다시 누르면 패널은 그대로라 알림이 없다 → 빛만 다시 흐르게
    if (pick != null && (id == null || id == before)) _restartPulse();
  }

  /// 고른 길 계산: 배치·고른 것·자리가 같으면 앞 것을 다시 쓴다. 빛이 흐르는 프레임마다 다시 하지 않는다 (11/13 검토 3).
  _Prepared? _prepare(NeuralLayout layout, _At? sel, _Geo g) {
    final old = _prepared;
    if (old != null && identical(old.layout, layout) && old.sel == sel && old.geo.same(g)) return old;
    _Prepared? next;
    if (sel != null) {
      final sameLit = old != null && identical(old.layout, layout) && old.sel == sel;
      next = _Prepared(layout, sel, g, sameLit ? old.lit : _Lit.of(layout, sel));
    }
    // 앞 것의 글자 배치는 이번 프레임이 끝난 뒤 버린다 (이미 기록한 그림이 쓰고 있을 수 있다).
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    return _prepared = next;
  }

  /// 한 프레임에 휠 이벤트가 여럿 와도 앞 이벤트가 바꾼 값 위에서 셈하도록, 빌드 때 잡은 자리 대신 지금 값으로 다시 잰다.
  _Geo _now(NeuralLayout layout) => _Geo(_size!, layout, _k, _off);

  void _zoomAt(double factor, double y, NeuralLayout layout) {
    final g = _now(layout);
    final k = (_k * factor).clamp(1.0, g.kMax);
    final idx = (y - g.top - g.off) / g.s;
    setState(() {
      _k = k;
      _off = _Geo.clampOff(y - g.top - idx * g.s0 * k, g.lh, g.n * g.s0 * k);
    });
  }

  void _panBy(double dy, NeuralLayout layout) {
    final g = _now(layout);
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

  Widget _canvas(NeuralLayout layout, _At? sel) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // 크기만 기억한다 (다시 맞추기·setState 없음 — 영역 크기에 반응해 상태를 바꾸면 떨림 고리가 생긴다, L-0005).
        // 이동값은 그릴 때 영역에 맞춰 잘라 쓴다. 고른 길 계산(_prepare)도 상태를 바꾸지 않고 그림·목록만 만든다.
        _size = size;
        final g = _Geo(size, layout, _k, _off);
        final prepared = _prepare(layout, sel, g);
        final hover = _find(layout, _hover);
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
                      _zoomAt(exp(-event.scrollDelta.dy / 300), event.localPosition.dy, layout);
                    }
                  },
                  onPointerPanZoomUpdate: (event) {
                    if (event.panDelta.dy != 0) _panBy(event.panDelta.dy, layout);
                    if ((event.scale - _lastScale).abs() > 0.001) {
                      _zoomAt(event.scale / _lastScale, event.localPosition.dy, layout);
                      _lastScale = event.scale;
                    }
                  },
                  onPointerPanZoomStart: (_) => _lastScale = 1,
                  child: MouseRegion(
                    onHover: (event) {
                      _mouse.value = event.localPosition;
                      final hit = g.hit(event.localPosition);
                      final key = hit == null ? null : _keyOf(layout, hit);
                      if (key != _hover) setState(() => _hover = key);
                    },
                    onExit: (_) {
                      if (_hover != null) setState(() => _hover = null);
                    },
                    child: GestureDetector(
                      onTapUp: (details) {
                        _focus.requestFocus();
                        _select(g.hit(details.localPosition), layout);
                      },
                      onVerticalDragUpdate: (details) => _panBy(details.delta.dy, layout),
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
                    opacity: prepared == null ? 0 : 1,
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOut,
                    child: const ColoredBox(color: Color(0x990d0b18)),
                  ),
                ),
              ),
              // 고른 길(정지 그림): 고른 것·자리가 바뀔 때만 그린다. 빛 흐름은 그 위 층이 프레임마다 따로 그린다 (11/13 검토 3).
              if (prepared != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(child: CustomPaint(painter: _PathPainter(prepared))),
                  ),
                ),
              if (prepared != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(child: CustomPaint(painter: _PulsePainter(prepared, _pulse))),
                  ),
                ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _HoverPainter(layout: layout, geo: g, hover: hover, prepared: prepared),
                  ),
                ),
              ),
              // 고른 길 이름표가 그 층 높이에 다 들어가지 않으면, 그 자리에 스크롤 목록으로 모두 보인다 (자르지 않음, 결정 6).
              if (prepared != null)
                for (final o in prepared.labels.overflow) _overflowList(o),
              if (hover != null) _tooltip(layout, hover, size),
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
                    _ToolButton(label: '+', onTap: () => _zoomAt(1.25, g.top + g.lh / 2, layout)),
                    const SizedBox(height: 4),
                    _ToolButton(label: '−', onTap: () => _zoomAt(0.8, g.top + g.lh / 2, layout)),
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

  Widget _overflowList(_Overflow o) => Positioned.fromRect(
    rect: o.rect,
    child: Container(
      key: ValueKey('neural-path-list-${o.layer.name}'),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      decoration: BoxDecoration(
        color: const Color(0xf0141224),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x33a78bfa)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(o.heading, style: const TextStyle(color: AppColors.graphLabel, fontSize: 11)),
          const SizedBox(height: 4),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: o.texts.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(o.texts[i], style: const TextStyle(color: Color(0xffffffff), fontSize: 11.5, height: 1.3)),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  /// 마우스를 올린 노드의 이름 전체와 종류 (이름표가 겹쳐 빠진 곳에서도 이름을 읽게). 마우스를 따라 움직인다.
  Widget _tooltip(NeuralLayout layout, _At hover, Size size) {
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
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<Offset?>(
          valueListenable: _mouse,
          builder: (context, at, _) => at == null
              ? const SizedBox.shrink()
              : Stack(
                  children: [
                    Positioned(
                      left: min(at.dx + 14, max(0.0, size.width - width - 8)),
                      top: min(at.dy + 14, max(0.0, size.height - 80)),
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

  /// 같은 배치에서 화면 자리가 같다.
  bool same(_Geo o) => size == o.size && s == o.s && off == o.off;

  /// 노트 사이가 이만큼 벌어질 때까지 확대한다 (긴 제목이 두세 줄로 보일 자리).
  double get kMax => max(4, 40 / s0);

  /// 은닉층 이름표가 보이기 시작하는 간격 (시안과 같은 12px).
  static const labelGap = 12.0;
  bool get showNoteLabels => s >= labelGap;

  /// 입력·주제 이름표가 바탕에 보이기 시작하는 간격.
  static const sideLabelGap = 13.0;

  /// 은닉층 이름표 폭: 은닉층 → 주제 사이의 반쯤. 넘치면 줄을 바꾼다 (자르지 않음, 결정 6).
  double get noteLabelWidth => max(80, (xOut - xH) * 0.6);
  double get inputLabelWidth => max(60, xIn - 20);
  double get topicLabelWidth => max(60, size.width - xOut - 18);

  static double clampOff(double off, double lh, double contentHeight) => min(0, max(lh - contentHeight, off));

  double yIn(int i) => top + (i + 0.5) * sIn;
  double yOut(int t) => top + (t + 0.5) * sOut;
  double yNote(int i) => top + off + (i + 0.5) * s;
  bool inView(double y) => y >= top - 4 && y <= top + lh + 4;

  /// 보이는 노트 범위 [lo, hi].
  int get lo => max(0, ((-off) / s).floor() - 1);
  int get hi => min(n - 1, ((lh - off) / s).ceil() + 1);

  /// 마우스 위치 → 노드.
  _At? hit(Offset at) {
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

/// 고른 길: 밝힐 노드와 선. 고를 때 한 번만 만든다.
class _Lit {
  _Lit();

  final inputs = <int>{};
  final topics = <int>{};

  /// 밝힐 노트 (은닉층 순서, 오름차순 — 보이는 범위만 이분 탐색으로 찾는다).
  Int32List notes = Int32List(0);

  /// 링크로 닿은 다른 주제 (반쯤 밝게, 점선).
  final faintTopics = <int>{};

  /// 입력 → 노트, 노트 → 자기 주제, 노트 → 이웃 주제(점선).
  final e1 = <(int, int)>[];
  final e2 = <(int, int)>[];
  final e3 = <(int, int)>[];

  static _Lit of(NeuralLayout layout, _At sel) {
    final lit = _Lit();
    void addNote(int i, {required bool withInputs}) {
      final n = layout.notes[i];
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
        final notes = layout.inputs[sel.i].notes;
        for (final i in notes) {
          lit.e1.add((sel.i, i));
          addNote(i, withInputs: false);
        }
        lit.notes = notes; // 배치가 오름차순으로 준다
      case _Layer.note:
        addNote(sel.i, withInputs: true);
        for (final t in layout.notes[sel.i].neighborTopics) {
          lit.faintTopics.add(t);
          lit.e3.add((sel.i, t));
        }
        lit.notes = Int32List.fromList([sel.i]);
      case _Layer.topic:
        lit.topics.add(sel.i);
        final t = layout.topics[sel.i];
        for (var i = t.start; i < t.start + t.count; i++) {
          addNote(i, withInputs: true);
        }
        lit.notes = Int32List.fromList([for (var i = t.start; i < t.start + t.count; i++) i]);
    }
    return lit;
  }

  /// 밝힌 노트 가운데 [lo, hi] 안에 있는 것 (오름차순).
  Iterable<int> notesIn(int lo, int hi) sync* {
    var a = 0, b = notes.length;
    while (a < b) {
      final m = (a + b) >> 1;
      if (notes[m] < lo) {
        a = m + 1;
      } else {
        b = m;
      }
    }
    for (var j = a; j < notes.length && notes[j] <= hi; j++) {
      yield notes[j];
    }
  }
}

/// 빛 흐름 한 단계에 그리는 선 수의 상한. 넘으면 고르게 골라 그린다 (11/13 검토 3: 1만 개에서 프레임마다 수천 개).
const _pulseLineCap = 600;

/// 빛 머리에 번짐(그라데이션)을 그리는 상한. 넘으면 둥근 점으로만 그린다.
const _pulseGlowCap = 48;

/// 밝힌 입력에 빛 번짐을 그리는 상한 (넘으면 점만).
const _litGlowCap = 120;

/// 고른 길에서 미리 계산한 것: 밝힐 노드·선([lit]), 고른 길 이름표 자리([labels]), 빛 흐름 표본 선.
/// 배치·고른 것·화면 자리가 바뀔 때만 만든다. 이름표 글자 배치는 이 객체가 가지고, 바뀔 때 버린다.
class _Prepared {
  _Prepared(this.layout, this.sel, this.geo, this.lit) {
    labels = _PathLabels.build(layout, sel, lit, geo);
    final g = geo;
    pulse1 = _sample(lit.e1, (x) => Offset(g.xIn, g.yIn(x)), (i) => Offset(g.xH, g.yNote(i)));
    pulse2 = _sample(lit.e2, (i) => Offset(g.xH, g.yNote(i)), (t) => Offset(g.xOut, g.yOut(t)));
    final arrive = lit.topics.take(24).toList();
    arrivals = Float32List.fromList([
      for (final t in arrive) ...[g.xOut, g.yOut(t)],
    ]);
    final most = max(pulse1.length, pulse2.length) ~/ 4;
    lineScratch = Float32List(most * 4);
    headScratch = Float32List(most * 2);
  }

  final NeuralLayout layout;
  final _At sel;
  final _Geo geo;
  final _Lit lit;
  late final _PathLabels labels;

  /// 빛 흐름 표본 선 (x0, y0, x1, y1)… — 대화 → 노트, 노트 → 주제.
  late final Float32List pulse1, pulse2;

  /// 빛이 도착하는 주제 자리 (x, y)….
  late final Float32List arrivals;

  /// 프레임마다 쓰는 빈 배열 (프레임마다 새로 만들지 않게).
  late final Float32List lineScratch, headScratch;

  static Float32List _sample(List<(int, int)> edges, Offset Function(int) a, Offset Function(int) b) {
    final step = max(1, (edges.length / _pulseLineCap).ceil());
    final out = Float32List(((edges.length + step - 1) ~/ step) * 4);
    var k = 0;
    for (var j = 0; j < edges.length; j += step) {
      final (u, v) = edges[j];
      final from = a(u), to = b(v);
      out[k++] = from.dx;
      out[k++] = from.dy;
      out[k++] = to.dx;
      out[k++] = to.dy;
    }
    return out;
  }

  void dispose() => labels.dispose();
}

/// 고른 길 이름표 한 개의 자리 (겹치지 않게 쌓은 뒤).
class _Placed {
  _Placed(this.text, this.painter, this.box, this.textAt, this.node, this.edge);

  final String text;
  final TextPainter painter;

  /// 어두운 판 자리 (글자 둘레 3px).
  final Rect box;
  final Offset textAt;

  /// 노드 자리와, 이름표가 노드에서 밀려났을 때 이을 이름표 쪽 끝.
  final Offset node;
  final Offset edge;
}

/// 층 높이에 다 들어가지 않는 고른 길 이름표: 그 층 이름표 자리에 스크롤 목록으로 보인다.
class _Overflow {
  _Overflow(this.layer, this.heading, this.texts, this.rect);

  final _Layer layer;
  final String heading;
  final List<String> texts;
  final Rect rect;
}

/// 고른 길 이름표 (11/13 검토 4). 고른 노드와 바로 이어진 노드(노트를 고르면 그 출처·주제·링크로 닿은 주제,
/// 대화를 고르면 그 노트·주제)의 이름표는 겹쳐도 건너뛰지 않는다. 층마다 노드 순서대로 위에서 아래로 쌓아
/// 서로 겹치지 않게 하고, 밀려난 이름표는 노드와 가는 선으로 잇는다. 층 높이에 다 들어가지 않으면 그 층은
/// 스크롤 목록([overflow])으로 모두 보인다. 이름표는 자르지 않는다 (결정 6).
class _PathLabels {
  final placed = <_Placed>[];
  final overflow = <_Overflow>[];

  /// 고른 길 이름표 자리 (다른 이름표가 피한다).
  final rects = <Rect>[];

  /// 이름표를 단 노드 (마우스 올림 이름표가 같은 것을 또 달지 않게).
  final keys = <_At>{};

  final _owned = <TextPainter>[];

  void dispose() {
    for (final p in _owned) {
      p.dispose();
    }
    _owned.clear();
  }

  static _PathLabels build(NeuralLayout layout, _At sel, _Lit lit, _Geo g) {
    final out = _PathLabels();
    final ins = <int>[], notes = <int>[], topics = <int>[];
    switch (sel.layer) {
      case _Layer.note:
        notes.add(sel.i);
        ins.addAll(layout.notes[sel.i].inputs);
        topics
          ..add(layout.notes[sel.i].topic)
          ..addAll(layout.notes[sel.i].neighborTopics);
      case _Layer.input:
        ins.add(sel.i);
        notes.addAll(lit.notesIn(g.lo, g.hi).where((i) => g.inView(g.yNote(i))));
        topics.addAll(lit.topics);
      case _Layer.topic:
        topics.add(sel.i);
    }
    String topicText(int t) => '${layout.topics[t].name}  ${layout.topics[t].count}';
    out._column(
      _Layer.input,
      [for (final x in ins) (x, layout.inputs[x].title, g.yIn(x))],
      g,
      sel,
      nodeX: g.xIn,
      textX: g.xIn - 12,
      width: g.inputLabelWidth,
      right: true,
      heading: '고른 길 · 대화·문서',
    );
    out._column(
      _Layer.note,
      [for (final i in notes) (i, layout.notes[i].title, g.yNote(i))],
      g,
      sel,
      nodeX: g.xH,
      textX: g.xH + 9,
      width: g.noteLabelWidth,
      right: false,
      heading: '고른 길 · 노트',
    );
    out._column(
      _Layer.topic,
      [for (final t in {...topics}) (t, topicText(t), g.yOut(t))],
      g,
      sel,
      nodeX: g.xOut,
      textX: g.xOut + 12,
      width: g.topicLabelWidth,
      right: false,
      heading: '고른 길 · 주제',
    );
    return out;
  }

  /// 한 층의 이름표를 노드 순서대로 쌓는다. [right]면 글 끝을 [textX]에 맞춘다.
  void _column(
    _Layer layer,
    List<(int, String, double)> items,
    _Geo g,
    _At sel, {
    required double nodeX,
    required double textX,
    required double width,
    required bool right,
    required String heading,
  }) {
    if (items.isEmpty) return;
    items.sort((a, b) => a.$3.compareTo(b.$3));
    final minTop = g.top - 8, maxBottom = g.top + g.lh + 8;
    // 한 줄 이름표(판 포함 약 23px)로도 다 들어가지 않으면 글자 배치 없이 바로 목록으로 (노트 수백 개를 배치하지 않게)
    const gap = 2.0;
    void toList() => overflow.add(
      _Overflow(
        layer,
        '$heading ${items.length}',
        [for (final it in items) it.$2],
        Rect.fromLTRB(right ? max(4, textX - width) : textX, minTop, right ? textX : min(g.size.width - 4, textX + width + 6), maxBottom),
      ),
    );
    if (items.length * (11.5 * 1.3 + 6 + gap) > maxBottom - minTop) {
      toList();
      return;
    }
    final painters = [
      for (final it in items) _layoutLabel(it.$2, width, strong: it.$1 == sel.i && layer == sel.layer),
    ];
    final tops = List<double>.filled(items.length, 0);
    var prevBottom = double.negativeInfinity;
    for (var j = 0; j < items.length; j++) {
      final h = painters[j].height + 6;
      tops[j] = max(max(items[j].$3 - h / 2, prevBottom + gap), minTop);
      prevBottom = tops[j] + h;
    }
    var limit = maxBottom;
    for (var j = items.length - 1; j >= 0; j--) {
      final h = painters[j].height + 6;
      if (tops[j] + h > limit) tops[j] = limit - h;
      limit = tops[j] - gap;
    }
    if (tops.first < minTop) {
      for (final p in painters) {
        p.dispose();
      }
      toList();
      return;
    }
    _owned.addAll(painters);
    for (var j = 0; j < items.length; j++) {
      final p = painters[j];
      final x = right ? textX - p.width : textX;
      final box = Rect.fromLTWH(x - 3, tops[j], p.width + 6, p.height + 6);
      placed.add(
        _Placed(
          items[j].$2,
          p,
          box,
          Offset(x, tops[j] + 3),
          Offset(nodeX, items[j].$3),
          Offset(right ? box.right : box.left, box.center.dy),
        ),
      );
      rects.add(box);
      keys.add((layer: layer, i: items[j].$1));
    }
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
    final watch = kReleaseMode ? null : (Stopwatch()..start());
    if (!kReleaseMode) neuralPaintCount++;
    _trimPainters();
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
    for (var i = 0; i < layout.inputs.length; i++) {
      final x = layout.inputs[i];
      _glowNode(canvas, Offset(g.xIn, g.yIn(i)), _nodeRadius(x.notes.length, layout.maxInputNotes, g.sIn),
          const Color(0xffe7e4f5),
          diamond: x.kind == NeuralInputKind.document);
    }
    for (var t = 0; t < layout.topics.length; t++) {
      _glowNode(canvas, Offset(g.xOut, g.yOut(t)), _nodeRadius(layout.topics[t].count, layout.maxTopicNotes, g.sOut),
          const Color(0xffffffff));
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
    if (g.sIn >= _Geo.sideLabelGap) {
      _labelPass(canvas, [
        for (var i = 0; i < layout.inputs.length; i++)
          _LabelItem(layout.inputs[i].title, Offset(g.xIn - 12, g.yIn(i)), g.inputLabelWidth, TextAlign.right),
      ]);
    }
    if (g.sOut >= _Geo.sideLabelGap) {
      _labelPass(canvas, [
        for (var t = 0; t < layout.topics.length; t++)
          _LabelItem('${layout.topics[t].name}  ${layout.topics[t].count}', Offset(g.xOut + 12, g.yOut(t)),
              g.topicLabelWidth, TextAlign.left),
      ]);
    }
    if (g.showNoteLabels) {
      _labelPass(canvas, [
        for (var p = g.lo; p <= g.hi; p++)
          if (g.inView(g.yNote(p)))
            _LabelItem(layout.notes[p].title, Offset(g.xH + 9, g.yNote(p)), g.noteLabelWidth, TextAlign.left, box: true),
      ]);
    }
    if (watch != null) neuralLastPaintMicros = watch.elapsedMicroseconds;
  }

  @override
  bool shouldRepaint(_BasePainter old) =>
      old.layout != layout || old.geo.size != geo.size || old.geo.s != geo.s || old.geo.off != geo.off;
}

/// 고른 길 (정지 그림): 밝힌 선·노드·이름표. 고른 것이나 자리가 바뀔 때만 다시 그린다 —
/// 빛이 흐르는 1.6초 동안 프레임마다 그리지 않는다 (11/13 검토 3).
class _PathPainter extends CustomPainter {
  _PathPainter(this.prepared);

  final _Prepared prepared;

  @override
  void paint(Canvas canvas, Size size) {
    if (!kReleaseMode) neuralPathPaintCount++;
    _trimPainters();
    final layout = prepared.layout;
    final g = prepared.geo;
    final lit = prepared.lit;
    final sel = prepared.sel;
    final r = (g.s * 0.34).clamp(0.7, 4.2);

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
    canvas.restore();

    // 밝힌 노드. 입력이 아주 많으면 빛 번짐 없이 점만 (번짐 하나가 그라데이션 하나다)
    final glowInputs = lit.inputs.length <= _litGlowCap;
    for (final i in lit.inputs) {
      final c = Offset(g.xIn, g.yIn(i));
      final radius = _nodeRadius(layout.inputs[i].notes.length, layout.maxInputNotes, g.sIn);
      final diamond = layout.inputs[i].kind == NeuralInputKind.document;
      if (glowInputs) {
        _glowNode(canvas, c, radius, _litNode, diamond: diamond);
      } else {
        _dotNode(canvas, c, radius, _litNode, diamond: diamond);
      }
    }
    for (final t in {...lit.topics, ...lit.faintTopics}) {
      final own = lit.topics.contains(t);
      _glowNode(canvas, Offset(g.xOut, g.yOut(t)), _nodeRadius(layout.topics[t].count, layout.maxTopicNotes, g.sOut),
          own ? _litNode : _litNode.withValues(alpha: 0.5));
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, g.top - 6, size.width, g.lh + 12));
    final dots = Path();
    final visibleNotes = lit.notesIn(g.lo, g.hi).where((i) => g.inView(g.yNote(i))).toList();
    for (final i in visibleNotes) {
      dots.addOval(Rect.fromCircle(center: Offset(g.xH, g.yNote(i)), radius: r + 0.6));
    }
    canvas.drawPath(dots, Paint()..color = const Color(0xffddd6fe));
    if (sel.layer == _Layer.note && g.inView(g.yNote(sel.i))) {
      final c = Offset(g.xH, g.yNote(sel.i));
      _glow(canvas, c, max(3, r + 1) * 3, AppColors.graphAccent.withValues(alpha: 0.85));
      canvas.drawCircle(c, max(2.2, r + 0.6), Paint()..color = const Color(0xffffffff));
    }
    canvas.restore();

    // 고른 길에 바로 닿지 않은 밝힌 이름표: 자리가 있을 때(또는 몇 개 안 될 때)만, 겹치면 건너뛴다.
    // 고른 길 이름표 자리는 피한다. 아주 많은 이름표를 배치하지 않게 간격으로 먼저 거른다 (11/13 검토 3).
    final path = prepared.labels;
    bool labelled(_Layer layer, int i) => path.keys.contains((layer: layer, i: i));
    final avoid = path.rects;
    if (g.sIn >= _Geo.sideLabelGap || lit.inputs.length <= 40) {
      _labelPass(canvas, [
        for (final i in lit.inputs)
          if (!labelled(_Layer.input, i))
            _LabelItem(layout.inputs[i].title, Offset(g.xIn - 12, g.yIn(i)), g.inputLabelWidth, TextAlign.right,
                strong: true),
      ], avoid: avoid);
    }
    final litTopics = {...lit.topics, ...lit.faintTopics};
    if (g.sOut >= _Geo.sideLabelGap || litTopics.length <= 40) {
      _labelPass(canvas, [
        for (final t in litTopics)
          if (!labelled(_Layer.topic, t))
            _LabelItem('${layout.topics[t].name}  ${layout.topics[t].count}', Offset(g.xOut + 12, g.yOut(t)),
                g.topicLabelWidth, TextAlign.left,
                strong: lit.topics.contains(t)),
      ], avoid: avoid);
    }
    if (g.showNoteLabels || visibleNotes.length <= 40) {
      _labelPass(canvas, [
        for (final i in visibleNotes)
          if (!labelled(_Layer.note, i))
            _LabelItem(layout.notes[i].title, Offset(g.xH + 9, g.yNote(i)), g.noteLabelWidth, TextAlign.left, box: true),
      ], avoid: avoid);
    }

    // 고른 길 이름표: 모두 단다 (겹치지 않게 쌓아 둔 자리). 노드에서 밀려났으면 가는 선으로 잇는다.
    final leader = Paint()
      ..strokeWidth = 1
      ..color = AppColors.graphAccent.withValues(alpha: 0.55);
    for (final pl in path.placed) {
      if ((pl.edge.dy - pl.node.dy).abs() > 3) canvas.drawLine(pl.node, pl.edge, leader);
      canvas.drawRRect(RRect.fromRectAndRadius(pl.box, const Radius.circular(4)), Paint()..color = const Color(0xe60e0c18));
      pl.painter.paint(canvas, pl.textAt);
      _logLabel(pl.text, pl.painter, pl.textAt, strong: true);
    }
  }

  @override
  bool shouldRepaint(_PathPainter old) => !identical(old.prepared, prepared);
}

/// 빛 흐름: 프레임마다 그린다. 미리 고른 표본 선(최대 [_pulseLineCap]개)을 한 번의 drawRawPoints로 긋고,
/// 빛 머리 번짐은 [_pulseGlowCap]개까지만 그린다 (11/13 검토 3).
class _PulsePainter extends CustomPainter {
  _PulsePainter(this.prepared, this.pulse) : super(repaint: pulse);

  final _Prepared prepared;
  final Animation<double> pulse;

  /// 빛이 한 번 흐른다: 대화 → 노트 (0~650ms), 노트 → 주제 (550~1200ms), 주제 도착 (1150~1600ms). 시안과 같은 시간.
  @override
  void paint(Canvas canvas, Size size) {
    final t = pulse.value * 1600;
    if (t <= 0 || t >= 1600) return;
    final g = prepared.geo;
    var lines = 0, glows = 0;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, g.top - 4, size.width, g.lh + 8));
    void seg(Float32List edges, double t0, double dur) {
      final p = (t - t0) / dur;
      final n = edges.length ~/ 4;
      if (p <= 0 || p >= 1.25 || n == 0) return;
      final head = min(1.0, p), tail = max(0.0, p - 0.28);
      final out = prepared.lineScratch, heads = prepared.headScratch;
      for (var k = 0; k < n; k++) {
        final x0 = edges[4 * k], y0 = edges[4 * k + 1], dx = edges[4 * k + 2] - x0, dy = edges[4 * k + 3] - y0;
        out[4 * k] = x0 + dx * tail;
        out[4 * k + 1] = y0 + dy * tail;
        out[4 * k + 2] = heads[2 * k] = x0 + dx * head;
        out[4 * k + 3] = heads[2 * k + 1] = y0 + dy * head;
      }
      final view = Float32List.sublistView(out, 0, n * 4);
      final a2 = max(0.05, min(0.95, sqrt(40 / n)));
      if (n <= 300) {
        canvas.drawRawPoints(
          ui.PointMode.lines,
          view,
          Paint()
            ..strokeWidth = 5
            ..strokeCap = StrokeCap.round
            ..color = _litNode.withValues(alpha: 0.35 * a2),
        );
      }
      canvas.drawRawPoints(
        ui.PointMode.lines,
        view,
        Paint()
          ..strokeWidth = n <= 300 ? 1.6 : 1
          ..color = const Color(0xffffffff).withValues(alpha: a2),
      );
      lines += n;
      if (p >= 1) return;
      if (n <= _pulseGlowCap) {
        for (var k = 0; k < n; k++) {
          _glow(canvas, Offset(heads[2 * k], heads[2 * k + 1]), 9, const Color(0xffffffff));
        }
        glows += n;
      } else {
        canvas.drawRawPoints(
          ui.PointMode.points,
          Float32List.sublistView(heads, 0, n * 2),
          Paint()
            ..strokeWidth = 4
            ..strokeCap = StrokeCap.round
            ..color = const Color(0xb3ffffff),
        );
      }
    }

    seg(prepared.pulse1, 0, 650);
    seg(prepared.pulse2, 550, 650);
    canvas.restore();
    final arrive = (t - 1150) / 450;
    if (arrive > 0 && arrive < 1) {
      final a = prepared.arrivals;
      for (var k = 0; k < a.length; k += 2) {
        _glow(canvas, Offset(a[k], a[k + 1]), 10 + 26 * arrive, AppColors.graphAccent.withValues(alpha: 1 - arrive));
      }
      glows += a.length ~/ 2;
    }
    if (!kReleaseMode) {
      neuralPulseFrames++;
      neuralPulseMaxLines = max(neuralPulseMaxLines, lines);
      neuralPulseMaxGlows = max(neuralPulseMaxGlows, glows);
    }
  }

  @override
  bool shouldRepaint(_PulsePainter old) => !identical(old.prepared, prepared);
}

/// 마우스 올린 노드: 빛 + 이름표 (겹쳐도 단다, 어두운 판 위). 노드 몇 개라 가볍다.
class _HoverPainter extends CustomPainter {
  _HoverPainter({required this.layout, required this.geo, required this.hover, required this.prepared});

  final NeuralLayout layout;
  final _Geo geo;
  final _At? hover;
  final _Prepared? prepared;

  @override
  void paint(Canvas canvas, Size size) {
    final pick = hover;
    if (pick == null) return;
    _trimPainters();
    final g = geo;
    final r = (g.s * 0.34).clamp(0.7, 4.2);
    // 고른 길 이름표로 이미 단 노드는 다시 달지 않는다 (같은 글이 두 번 겹쳐 보이지 않게)
    final already = prepared?.labels.keys.contains(pick) ?? false;
    final _LabelItem item;
    switch (pick.layer) {
      case _Layer.note:
        final y = g.yNote(pick.i);
        if (!g.inView(y)) return;
        _glow(canvas, Offset(g.xH, y), max(3, r + 1) * 3, const Color(0xd9ffffff));
        canvas.drawCircle(Offset(g.xH, y), max(2.2, r + 0.6), Paint()..color = const Color(0xffffffff));
        item = _LabelItem(layout.notes[pick.i].title, Offset(g.xH + 9, y), g.noteLabelWidth, TextAlign.left,
            box: true, strong: true);
      case _Layer.input:
        item = _LabelItem(layout.inputs[pick.i].title, Offset(g.xIn - 12, g.yIn(pick.i)), g.inputLabelWidth,
            TextAlign.right,
            box: true, strong: true);
      case _Layer.topic:
        item = _LabelItem('${layout.topics[pick.i].name}  ${layout.topics[pick.i].count}',
            Offset(g.xOut + 12, g.yOut(pick.i)), g.topicLabelWidth, TextAlign.left,
            box: true, strong: true);
    }
    if (!already) _drawLabel(canvas, item, _painter(item.text, item.maxWidth, item.strong));
  }

  @override
  bool shouldRepaint(_HoverPainter old) =>
      old.layout != layout || old.hover != hover || !identical(old.prepared, prepared) || !old.geo.same(geo);
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
  _dotNode(canvas, c, r, color, diamond: diamond);
}

/// 점(또는 마름모)만.
void _dotNode(Canvas canvas, Offset c, double r, Color color, {bool diamond = false}) {
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
  _LabelItem(this.text, this.at, this.maxWidth, this.align, {this.box = false, this.strong = false});

  final String text;

  /// 글 시작점(왼쪽 맞춤) 또는 끝점(오른쪽 맞춤)의 x와 노드 y.
  final Offset at;
  final double maxWidth;
  final TextAlign align;

  /// 뒤에 어두운 판을 깐다 (선 위에서도 읽히게).
  final bool box;
  final bool strong;
}

Offset _textTopLeft(_LabelItem it, TextPainter painter) =>
    Offset(it.align == TextAlign.right ? it.at.dx - painter.width : it.at.dx, it.at.dy - painter.height / 2);

/// 이름표를 위에서 아래로 단다. 앞 이름표나 [avoid](고른 길 이름표)와 겹치면 건너뛴다. 긴 제목은 줄을 바꿔 다 보인다.
/// 받은 글자 배치는 그 자리에서 바로 그린다 (붙잡아 두었다가 나중에 그리지 않는다, 11/13 검토 2).
void _labelPass(Canvas canvas, List<_LabelItem> items, {List<Rect> avoid = const []}) {
  items.sort((a, b) => a.at.dy.compareTo(b.at.dy));
  var lastBottom = double.negativeInfinity;
  for (final it in items) {
    final painter = _painter(it.text, it.maxWidth, it.strong);
    final at = _textTopLeft(it, painter);
    if (at.dy < lastBottom + 1) continue;
    final rect = (at & painter.size).inflate(3);
    if (avoid.any(rect.overlaps)) continue;
    _drawLabel(canvas, it, painter);
    lastBottom = at.dy + painter.height;
  }
}

void _drawLabel(Canvas canvas, _LabelItem it, TextPainter painter) {
  final topLeft = _textTopLeft(it, painter);
  if (it.box) {
    canvas.drawRRect(
      RRect.fromRectAndRadius((topLeft & painter.size).inflate(3), const Radius.circular(4)),
      Paint()..color = const Color(0xd90e0c18),
    );
  }
  painter.paint(canvas, topLeft);
  _logLabel(it.text, painter, topLeft, strong: it.strong);
}

/// [strong]: 밝힌 이름표(고른 길·마우스 올림·밝힌 노드).
void _logLabel(String text, TextPainter painter, Offset at, {required bool strong}) {
  if (kReleaseMode) return;
  neuralLabelLog.add((text: text, lines: painter.computeLineMetrics().length, rect: at & painter.size, strong: strong));
  if (neuralLabelLog.length > 2000) neuralLabelLog.removeRange(0, 1000);
}

/// 이름표 글자 배치 캐시 (배치가 그리기에서 가장 무겁다). 줄 수 제한·말줄임 없이 [maxWidth]에서 줄을 바꾼다.
/// 오래 안 쓴 것부터 버린다(LRU). 버리기는 그리기를 시작할 때만([_trimPainters]) 한다: 예전에는 한 번의 그리기
/// 도중 800개를 넘으면 전부 버려, 그 그리기가 나중에 그리려고 쥐고 있던 이름표가 이미 버려진 채로 그려졌다 (11/13 검토 2).
final _painters = <(String, int, bool), TextPainter>{};

TextPainter _painter(String text, double maxWidth, bool strong) {
  final key = (text, maxWidth.round(), strong);
  final hit = _painters.remove(key);
  if (hit != null) return _painters[key] = hit; // 맨 뒤(최근)로
  return _painters[key] = _layoutLabel(text, key.$2.toDouble(), strong: strong);
}

/// 그리기 시작에만 부른다. 이번 그리기에서 받은 글자 배치는 다음 그리기 전까지 버리지 않는다.
void _trimPainters() {
  while (_painters.length > neuralPainterCacheLimit) {
    _painters.remove(_painters.keys.first)!.dispose();
  }
}

/// 이름표 글자 배치. 줄 수 제한·말줄임 없음 (결정 6).
TextPainter _layoutLabel(String text, double maxWidth, {required bool strong}) => TextPainter(
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
)..layout(maxWidth: maxWidth.roundToDouble());

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
