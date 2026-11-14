import 'dart:math';
import 'dart:ui' as ui;

import 'package:brain_core/brain_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';
import 'graph_motion.dart';
import 'neural_view.dart';

/// 그래프 맞추기 횟수 (시험용: 화면 배율을 바꿔도 다시 맞추지 않는지 본다).
@visibleForTesting
int graphFitCount = 0;

/// 성능 시험용: 그래프를 실제로 그린 횟수 (painter.paint).
int graphPaintCount = 0;

/// 노드 범위 둘레에 더 두는 그림 영역(끌기 여유)의 가장 작은 값 (그래프 좌표). 노드를 이만큼 바깥까지 끌 수 있다
/// (설계서_프롬프트이후 5.6). 보통 배율(0.6 이상)에서는 이 값이다.
const graphDragRoom = 200.0;

/// 끌기 여유를 화면에서 이만큼(px) 둔다 (설계서_프롬프트이후 5.6, 11/14).
const graphDragRoomPixels = 120.0;

/// 끌기 여유의 가장 큰 값 (그래프 좌표). 아주 작게 줄였을 때 그림 영역이 한없이 커지지 않게.
const graphDragRoomMax = 1500.0;

/// 배율 [scale]에서의 끌기 여유 (그래프 좌표): 화면 약 [graphDragRoomPixels]px, [graphDragRoom]~[graphDragRoomMax].
///
/// 예전에는 늘 200이었다. 노트 1만 개를 [맞추기]하면 배율이 약 0.14라 화면에서 28px뿐이어서, 무리 가장자리 노드를
/// 바깥으로 끌면 곧바로 멈췄다 (설계서_프롬프트이후 5.6, 11/14 실제 앱에서 발견).
double graphDragRoomFor(double scale) =>
    (graphDragRoomPixels / max(scale, 1e-6)).clamp(graphDragRoom, graphDragRoomMax);

/// 시험용: 지금 그림 영역의 원점(그래프 좌표, 노드 범위 왼쪽 위 - 여백 - 끌기 여유)과 끌기 여유.
/// 그래프 좌표 p는 화면에서 `transform(p - origin)`에 그려진다.
@visibleForTesting
({Offset origin, double room}) graphContentForTest = (origin: Offset.zero, room: graphDragRoom);

/// 시험용: 지금 그래프 보기의 노드 끌기 상태 (옮긴 자리, 설계서_프롬프트이후 5.6).
@visibleForTesting
GraphMotion? graphMotionForTest;

/// 뇌 그래프 (설계서 3.3·5.5). 어두운 배경 + 빛나는 노드, 추천 연결은 점선.
class GraphView extends ConsumerStatefulWidget {
  const GraphView({super.key});

  @override
  ConsumerState<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends ConsumerState<GraphView> with TickerProviderStateMixin {
  final _transform = TransformationController();

  /// 부드러운 확대·축소 (설계서_프롬프트이후 5.6): [+]·[−]·[맞추기]·휠은 0.25초 동안 끝이 느려지게 옮긴다.
  /// 트랙패드 손가락 확대·끌기는 지금처럼 바로 따라온다.
  static const zoomDuration = Duration(milliseconds: 250);
  late final _zoomAnim = AnimationController(vsync: this, duration: zoomDuration)
    ..addListener(_zoomTick)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _zoomDone();
    });
  Matrix4? _zoomFrom;

  /// 움직이는 중인 확대의 도착 값. 빠르게 여러 번 누르거나 휠을 굴리면 이 값 위에 이어서 셈해 튀지 않는다.
  Matrix4? _zoomTo;

  /// 휠 한 칸 직전 상태. InteractiveViewer가 휠을 받아 바로 바꾼 변환을 되돌리고 부드럽게 다시 옮기는 데 쓴다.
  ({Matrix4 matrix, double lastScale, Matrix4? target})? _beforeWheel;

  /// 노드가 이보다 많으면 확대가 움직이는 동안 바탕을 다시 그리지 않고 끝난 뒤 한 번만 그린다.
  bool _isHeavy = false;

  /// 노드 끌기·[원래대로] (설계서_프롬프트이후 5.6). 옮긴 자리는 이 화면에만 있고 저장하지 않는다.
  final _motion = GraphMotion();
  late final Ticker _motionTicker = createTicker(_motionTick);
  Duration _lastMotionTick = Duration.zero;

  /// [원래대로]: 옮긴 노드가 0.4초 동안 원래 배치로 돌아간다.
  static const resetDuration = Duration(milliseconds: 400);
  late final AnimationController _resetAnim = AnimationController(vsync: this, duration: resetDuration)
    ..addListener(() => _motion.resetTick(Curves.easeInOutCubic.transform(_resetAnim.value)))
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _finishReset();
    });

  /// 옮긴 자리의 기준인 원래 배치 (graph_layout에서 읽은 값). 배치가 바뀌면(노트 추가·[다시 배치]) 옮긴 자리를 버린다.
  Map<String, Point<double>>? _motionBase;

  /// 노드를 잡은 자리와 노드 가운데의 차이 (잡은 곳이 그대로 손 밑에 있게).
  Offset _grab = Offset.zero;

  /// 이름표를 다는 노드 (바탕 그림 기준이 같으면 다시 셈하지 않는다).
  (int, Set<String>)? _labeled;

  bool _isLocal = false;
  /// 추천 연결을 그린다 (기본 켬). 끄면 고른 노드의 연결만 그린다.
  bool _showSuggested = true;

  /// [그물 | 신경망] 중 신경망 보기 (설계서_프롬프트이후 5.3). 그물 보기는 그대로 두고 바꿔 보인다.
  bool _isNeural = false;

  Widget _viewToggle() => NeuralToggle(isNeural: _isNeural, onChanged: (v) => setState(() => _isNeural = v));

  /// 폴더(뇌) 하나만 보기. null이면 전체.
  String? _topic;
  String? _fittedKey;
  String? _hovered;

  /// 지난번 그린 영역 크기. 화면 배율·창·패널 크기가 바뀌면 그만큼 옮겨 가운데를 지킨다.
  Size? _lastViewport;

  double _lastScale = 1;

  /// 지금 끌기 여유 (그래프 좌표, [graphDragRoomFor]). 확대 비율([_lastScale])이 바뀌면 [_updateRoom]이 맞춘다.
  double _room = graphDragRoom;

  /// 화면 끌기·손가락 확대 중 (InteractiveViewer). 이때는 끌기 여유를 바꾸지 않는다: 그림 원점이 움직이면
  /// InteractiveViewer가 잡아 둔 확대 기준점(그림 좌표)이 어긋나 화면이 한 번 튄다. 손을 떼면 맞춘다.
  bool _isInteracting = false;

  @override
  void initState() {
    super.initState();
    graphMotionForTest = _motion;
    // 확대할 때 글자 크기·선 굵기를 맞추려고 다시 그린다 (크게 바뀔 때만).
    _transform.addListener(() {
      // 노드가 많으면 부드러운 확대 도중에는 바탕을 다시 그리지 않는다 (0.25초 동안 여러 번 그리면 버벅인다). 끝나면 맞춘다.
      if (_isHeavy && _zoomAnim.isAnimating) return;
      _syncScale();
    });
  }

  void _syncScale() {
    final scale = _transform.value.getMaxScaleOnAxis();
    if ((scale - _lastScale).abs() / _lastScale > 0.08) {
      _lastScale = scale;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _motionTicker.dispose();
    _resetAnim.dispose();
    _motion.dispose();
    _zoomAnim.dispose();
    _transform.dispose();
    super.dispose();
  }

  bool get _reduceMotion => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [target]까지 부드럽게 옮긴다. 움직이는 중이면 지금 자리에서 새 도착 값으로 이어 간다 (멈췄다 튀지 않음).
  void _animateTo(Matrix4 target, {bool smooth = true}) {
    if (!smooth || _reduceMotion) {
      _stopZoom();
      _transform.value = target;
      return;
    }
    _zoomFrom = _transform.value.clone();
    _zoomTo = target;
    _zoomAnim.forward(from: 0);
  }

  void _zoomTick() {
    final from = _zoomFrom, to = _zoomTo;
    if (from == null || to == null) return;
    // 확대·이동만 있는 행렬이라 칸마다 섞으면 된다. 확대 기준점은 섞는 동안에도 같은 자리에 머문다.
    final t = Curves.easeOutCubic.transform(_zoomAnim.value);
    final m = Matrix4.zero();
    for (var i = 0; i < 16; i++) {
      m.storage[i] = from.storage[i] + (to.storage[i] - from.storage[i]) * t;
    }
    _transform.value = m;
  }

  /// 끌기 여유를 지금 배율에 맞춘다 (설계서_프롬프트이후 5.6, 11/14).
  ///
  /// 그림 원점(노드 범위 왼쪽 위 - 여유)이 바뀐 여유만큼 옮겨지므로, 같은 그래프 좌표가 화면 같은 자리에 남게 변환을
  /// 반대로 옮긴다 (움직이는 확대의 출발·도착 값도). 그래서 맞추기·보던 자리·저장된 배치는 그대로다.
  /// 확대 비율이 바뀔 때만(바탕을 어차피 다시 그릴 때) 불리므로 바탕을 더 그리지 않는다.
  void _updateRoom() {
    final want = graphDragRoomFor(_lastScale);
    if (want == _room || _isInteracting || _motion.isSimulating) return;
    // 옮긴 노드가 있으면 줄이지 않는다: 바깥에 둔 노드가 그림 영역 밖으로 나가면 다시 잡을 수 없다.
    if (want < _room && _motion.hasMoved) return;
    final d = want - _room;
    _room = want;
    // 그림 좌표가 (d, d)만큼 커지므로 변환 오른쪽에 (-d, -d) 옮기기를 곱한다: 화면 = 변환(그림 좌표 - d).
    Matrix4 shift(Matrix4 m) => m.clone()..translateByDouble(-d, -d, 0, 1);
    if (_zoomFrom != null) _zoomFrom = shift(_zoomFrom!);
    if (_zoomTo != null) _zoomTo = shift(_zoomTo!);
    _transform.value = shift(_transform.value);
  }

  void _zoomDone() {
    _zoomFrom = null;
    _zoomTo = null;
    _syncScale();
  }

  /// 움직이던 확대를 그 자리에서 멈춘다.
  void _stopZoom() {
    if (_zoomAnim.isAnimating) _zoomAnim.stop();
    _zoomDone();
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

  /// 위 폴더 칩 묶음. 주제가 많으면 칩이 여러 줄로 감겨 [_fitTop]보다 높아진다.
  final _chipsKey = GlobalKey();

  /// 위 도구 줄이 실제로 차지하는 높이 (칩 묶음 아래 끝 + 여백). [맞추기]가 그래프를 이 아래에 둔다.
  /// 노트 1만 개·주제 40개에서 칩이 다섯 줄(약 180px)이 되자, 84px로 못박은 자리 때문에 그래프 윗부분과
  /// 그 연결선이 칩 뒤로 들어갔다 (설계서_프롬프트이후 5.6, 11/14 실제 앱에서 발견).
  double _toolbarHeight() {
    final box = _chipsKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return _fitTop;
    return max(_fitTop, 10 + box.size.height + 10); // Positioned top 10 + 칩 + 아래 여백 10
  }

  /// [smooth]: [맞추기] 버튼은 부드럽게, 처음 열 때·보는 대상이 바뀔 때는 바로 맞춘다 (처음 열 때 움직임 없음, 5.6).
  void _fit(Rect bounds, Size viewport, {bool smooth = false}) {
    graphFitCount++;
    // 영역이 낮으면 비워 두지 않는다 (그래프가 지나치게 작아진다).
    final hasRoom = viewport.height > 360;
    // 도구 줄이 영역의 40%를 넘으면(창이 낮고 주제가 아주 많음) 그래프가 지나치게 작아지지 않게 거기서 멈춘다.
    final top = hasRoom ? min(_toolbarHeight(), viewport.height * 0.4) : 0.0;
    final usable = viewport.height - top - (hasRoom ? _fitBottom : 0.0);
    final scale = min(
      viewport.width / max(bounds.width, 1),
      usable / max(bounds.height, 1),
    ).clamp(0.05, 3.0);
    final dx = (viewport.width - bounds.width * scale) / 2 - bounds.left * scale;
    final dy = top + (usable - bounds.height * scale) / 2 - bounds.top * scale;
    // z축도 같은 배율로 둔다. InteractiveViewer(휠 확대)와 아래 배율 읽기는 getMaxScaleOnAxis로 x·y·z 중
    // 가장 큰 값을 읽는다. z를 1로 두면 축소(배율 < 1)한 상태가 늘 1.0으로 읽혀, 클릭 범위·글자 크기·
    // 휠 확대 한도가 틀어졌다 (11/12 K-38, graph_focus_test가 [−]를 눌러도 배율 1.0이던 원인).
    _animateTo(
      Matrix4.identity()
        ..translateByDouble(dx, dy, 0, 1)
        ..scaleByDouble(scale, scale, scale, 1),
      smooth: smooth,
    );
  }

  /// 영역 크기가 바뀌면 보던 가운데가 그대로 가운데에 오게 옮긴다 (다시 맞추지 않음).
  /// 같은 프레임 안에서 옮겨야 한 프레임 늦게 따라가며 튀지 않는다. 옮기기만 하고 확대 비율은
  /// 그대로라 [_transform] 리스너의 setState(확대 비율이 바뀔 때만)는 불리지 않는다.
  void _keepCenter(Size viewport) {
    final last = _lastViewport;
    if (last == null || last == viewport) return;
    final dx = (viewport.width - last.width) / 2;
    final dy = (viewport.height - last.height) / 2;
    Matrix4 shift(Matrix4 m) => Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..multiply(m);
    // 부드러운 확대 중이면 출발·도착 값도 같이 옮긴다 (다음 프레임에 옛 자리로 돌아가지 않게).
    if (_zoomFrom != null) _zoomFrom = shift(_zoomFrom!);
    if (_zoomTo != null) _zoomTo = shift(_zoomTo!);
    _transform.value = shift(_transform.value);
  }

  /// [focal](보이는 영역 기준)을 기준으로 확대·축소. 버튼은 가운데, 휠은 마우스 자리.
  /// 움직이는 중이면 도착 값 위에 이어서 셈한다: [+]를 빠르게 세 번 누르면 1.25³배로 끊김 없이 간다.
  void _zoomBy(double factor, Offset focal, {bool smooth = true}) {
    final base = _zoomTo ?? _transform.value;
    final scale = base.getMaxScaleOnAxis();
    final f = (scale * factor).clamp(_minScale, _maxScale) / scale;
    _animateTo(
      Matrix4.identity()
        ..translateByDouble(focal.dx, focal.dy, 0, 1)
        ..scaleByDouble(f, f, f, 1) // z도 함께 (_fit 설명)
        ..translateByDouble(-focal.dx, -focal.dy, 0, 1)
        ..multiply(base),
      smooth: smooth,
    );
  }

  static const _minScale = 0.05;
  static const _maxScale = 6.0;

  /// 휠 한 칸 (설계서_프롬프트이후 5.6). InteractiveViewer는 휠을 받으면 바로 배율을 바꾼다(끌 수 없음).
  /// 그 직전 값을 [InteractiveViewer.onInteractionStart]에서 잡아 두었다가, 바깥 Listener(InteractiveViewer 다음에 불림)에서
  /// 되돌리고 같은 배율로 부드럽게 다시 옮긴다. 한 이벤트 처리 안에서 일어나 중간 값이 그려지지는 않는다.
  void _onWheel(PointerSignalEvent event) {
    final before = _beforeWheel;
    _beforeWheel = null;
    if (event is! PointerScrollEvent || event.kind == PointerDeviceKind.trackpad || event.scrollDelta.dy == 0) return;
    if (before == null) return;
    _transform.value = before.matrix;
    _lastScale = before.lastScale;
    _zoomTo = before.target;
    // InteractiveViewer와 같은 셈 (scaleFactor 기본 200)
    _zoomBy(exp(-event.scrollDelta.dy / 200), event.localPosition);
  }

  void _motionTick(Duration elapsed) {
    final dt = (elapsed - _lastMotionTick).inMicroseconds / 1e6;
    _lastMotionTick = elapsed;
    if (!_motion.step(dt)) _motionTicker.stop();
  }

  /// 노드 끌기 시작 (설계서_프롬프트이후 5.6). 끈 노드 주변만 움직이는 층으로 옮긴다.
  void _dragStart(String id, Offset world, Map<String, Point<double>> positions, List<NoteLink> drawn, Rect area) {
    final p = _motion.moved[id] ?? positions[id]!;
    _grab = Offset(p.x, p.y) - world;
    // 움직이는 층에 새로 들어온 노드가 있으면 바탕을 한 번 다시 그려 그 노드를 뺀다 (같은 노드를 다시 끌면 그리지 않음).
    if (_motion.begin(id, positions, drawn, springs: !_reduceMotion, area: area)) setState(() {});
    if (!_motionTicker.isActive) {
      _lastMotionTick = Duration.zero;
      _motionTicker.start();
    }
  }

  /// [원래대로]: 옮긴 노드를 저장된 배치로 0.4초 동안 되돌린다. graph_layout은 처음부터 건드리지 않았다.
  void _reset() {
    final base = _motionBase;
    if (base == null || !_motion.hasMoved || _motion.isResetting) return;
    _motionTicker.stop();
    if (_reduceMotion) {
      _finishReset();
      return;
    }
    _motion.startReset(base);
    _resetAnim.forward(from: 0);
    setState(() {}); // 되돌리는 동안 버튼을 끈다
  }

  void _finishReset() {
    _motion.clear();
    if (mounted) setState(() {});
  }

  String? _hit(Offset world, Map<String, Point<double>> positions, double scale) {
    String? best;
    var bestDist = 14 / scale;
    for (final e in positions.entries) {
      final p = _motion.moved[e.key] ?? e.value;
      final d = (Offset(p.x, p.y) - world).distance;
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
      // 신경망 보기일 때는 그물 배치를 지켜보지 않는다: 지켜보는 곳이 없으면 노트가 바뀌어도 다시 계산하지 않고
      // (1만 개에서 전체 배치 약 13초), 그물로 돌아올 때 한 번만 계산한다 (설계서_프롬프트이후 5.3, 11/13 검토 6).
      child: _isNeural ? NeuralView(toggle: _viewToggle()) : _mesh(context, theme, notes, allLinks, selected, docs),
    );
  }

  /// 그물 보기. 배치 중·실패·빈 지식 폴더에서도 [그물 | 신경망] 버튼은 늘 보인다: 그물 배치가 끝나야만 신경망으로
  /// 갈 수 있으면, 노트 1만 개에서 배치를 기다리는 동안이나 배치가 실패했을 때 신경망 보기에 갈 수 없었다 (11/13 검토 6).
  Widget _mesh(
    BuildContext context,
    ShadThemeData theme,
    List<IndexedDoc> notes,
    List<NoteLink> allLinks,
    String? selected,
    Map<String, IndexedDoc> docs,
  ) {
    Widget withToggle(Widget child) => Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(top: 10, left: 10, child: _viewToggle()),
      ],
    );
    return ref.watch(graphLayoutProvider).when(
        loading: () => withToggle(const Center(
          child: Text('그래프 배치 중…', style: TextStyle(color: AppColors.graphLabel)),
        )),
        error: (e, _) => withToggle(Center(
          child: Text('그래프를 그리지 못했습니다: $e', style: const TextStyle(color: AppColors.graphLabel)),
        )),
        data: (allPositions) {
          if (allPositions.isEmpty) {
            return withToggle(const Center(
              child: Text(
                '아직 노트가 없습니다. 노트가 생기면 주제별로 모여 이어집니다.',
                style: TextStyle(color: AppColors.graphLabel, fontSize: 13),
              ),
            ));
          }
          if (!identical(allPositions, _motionBase)) {
            // 배치가 새로 계산됐다: 옮긴 자리는 옛 배치 기준이라 버린다 (빌드 중이라 알리지 않음, 아래에서 새로 그린다).
            if (_motionBase != null) {
              _motionTicker.stop();
              _resetAnim.stop();
              _motion.clear(notify: false);
            }
            _motionBase = allPositions;
          }
          final isLocal = _isLocal && selected != null && allPositions.containsKey(selected);
          var visible = isLocal
              ? _neighborhood(selected, allLinks)
              : allPositions.keys.toSet();
          if (_topic != null) {
            visible = {for (final id in visible) if (docs[id]?.topicPath == _topic) id};
          }
          final positions = {
            for (final id in visible) id: ?allPositions[id],
          };
          final links = [
            for (final l in allLinks)
              if (positions.containsKey(l.fromId) && positions.containsKey(l.toId)) l,
          ];
          final topics = {for (final d in notes) d.topicPath}.toList()..sort();
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
          // [이 노트 주변] + 다른 주제 칩처럼 보이는 노드가 0개일 수 있다. 예전에는 reduce가 터져 화면이 오류로 바뀌었다
          // (11/11 K-37). 빈 영역을 그리고 도구 줄은 그대로 두어 칩을 다시 고를 수 있게 한다.
          final bounds = positions.isEmpty
              ? const Rect.fromLTRB(-200, -150, 200, 150)
              : Rect.fromLTRB(
                  xs.reduce(min) - 80,
                  ys.reduce(min) - 60,
                  xs.reduce(max) + 80,
                  ys.reduce(max) + 60,
                );
          _isHeavy = positions.length > _GraphPainter.manyNodes;
          // 바탕 그림 기준: 같으면 다시 그리지 않는다. 움직이는 층의 노드가 바뀌면(끌기 시작·원래대로) 한 번 다시 그린다.
          final labelKey = Object.hash(
            identityHashCode(allPositions),
            identityHashCode(allLinks),
            identityHashCode(notes),
            isLocal ? selected : null,
            _topic,
            _showSuggested,
            _lastScale,
          );
          if (_labeled?.$1 != labelKey) _labeled = (labelKey, _GraphPainter.labeledOf(positions, degree, _lastScale));
          final labeled = _labeled!.$2;
          final live = _motion.live;
          final liveLinks = live.isEmpty
              ? const <NoteLink>[]
              : [
                  for (final l in drawn)
                    if (live.contains(l.fromId) || live.contains(l.toId)) l,
                ];
          // 노드가 그림 밖으로 나가면 다시 잡을 수 없어 그림 영역 안에서만 움직인다.
          // 그림 영역: 노드 범위 둘레에 끌기 여유([_room], 화면 약 120px)를 둔다. 노드를 범위 밖으로 끌어도 다시 잡고 마우스를
          // 올릴 수 있게 (그림 밖은 눌러도 받지 않는다). 맞추기는 그대로 노드 범위(bounds)에 맞춘다.
          _updateRoom();
          final content = bounds.inflate(_room);
          graphContentForTest = (origin: content.topLeft, room: _room);
          final dragArea = content.deflate(10);
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
                WidgetsBinding.instance.addPostFrameCallback((_) => _fit(bounds.shift(-content.topLeft), viewport));
              } else {
                _keepCenter(viewport);
              }
              _lastViewport = viewport;
              return Stack(
                children: [
                  Positioned.fill(
                    child: Listener(
                      onPointerSignal: _onWheel,
                      child: InteractiveViewer(
                        transformationController: _transform,
                        constrained: false,
                        boundaryMargin: const EdgeInsets.all(double.infinity),
                        minScale: _minScale,
                        maxScale: _maxScale,
                        onInteractionStart: (_) {
                          _isInteracting = true;
                          // 휠이면 _onWheel이 되돌릴 값. 끌기·손가락 확대면 움직이던 확대를 그 자리에서 멈춘다 (손이 우선).
                          _beforeWheel = (matrix: _transform.value.clone(), lastScale: _lastScale, target: _zoomTo);
                          if (_zoomAnim.isAnimating) {
                            _zoomAnim.stop();
                            _zoomFrom = null;
                            _zoomTo = null;
                          }
                        },
                        onInteractionEnd: (_) {
                          _isInteracting = false;
                          // 손가락 확대 중에 미뤄 둔 끌기 여유를 맞춘다 (바뀔 때만 다시 빌드).
                          if (graphDragRoomFor(_lastScale) != _room && mounted) setState(() {});
                        },
                        child: MouseRegion(
                          onHover: (event) {
                            final scale = _transform.value.getMaxScaleOnAxis();
                            final hit = _hit(event.localPosition + content.topLeft, positions, scale);
                            if (hit != _hovered) setState(() => _hovered = hit);
                          },
                          onExit: (_) => setState(() => _hovered = null),
                          child: GestureDetector(
                            onTapUp: (details) {
                              final scale = _transform.value.getMaxScaleOnAxis();
                              final hit = _hit(details.localPosition + content.topLeft, positions, scale);
                              ref.read(selectedNoteProvider.notifier).select(hit);
                            },
                            // 노드 위에서 누르고 끌면 노드를 끈다. 빈 곳에서 끌면 지금처럼 그래프를 옮긴다 (InteractiveViewer).
                            // 누른 자리가 노드가 아니면 이 인식기는 아예 받지 않는다. 움직이지 않고 떼면 위 탭(고르기)이 이긴다.
                            child: RawGestureDetector(
                              gestures: {
                                _NodeDragRecognizer: GestureRecognizerFactoryWithHandlers<_NodeDragRecognizer>(
                                  _NodeDragRecognizer.new,
                                  (r) => r
                                    ..dragStartBehavior = DragStartBehavior.down
                                    ..canStart = ((local) =>
                                        !_motion.isResetting &&
                                        _hit(local + content.topLeft, positions, _transform.value.getMaxScaleOnAxis()) != null)
                                    ..onStart = (d) {
                                      final world = d.localPosition + content.topLeft;
                                      final id = _hit(world, positions, _transform.value.getMaxScaleOnAxis());
                                      if (id != null) _dragStart(id, world, positions, drawn, dragArea);
                                    }
                                    ..onUpdate = ((d) => _motion.dragTo(d.localPosition + content.topLeft + _grab))
                                    ..onEnd = ((_) => _motion.release())
                                    ..onCancel = _motion.release,
                                ),
                              },
                              // 끌기·확대 때 InteractiveViewer는 변환만 바꾼다. 경계로 감싸 그림을 다시 그리지 않고
                              // 이미 그린 층을 옮기게 한다 (11/07 랙 측정: 끌기 40프레임에 37번 다시 그림).
                              // 바탕(모든 노드·연결)은 데이터·확대 단계가 바뀔 때만 그린다. 마우스 올림·선택은 그래프 밖
                              // 위 층(_FocusPainter)이 그린다 (11/07 노트 1만 개 측정: 마우스를 올릴 때마다 바탕까지 다시 그려 1.4초씩 멈췄다).
                              // 노드를 끄는 동안에는 움직이는 층(_MotionPainter, 끈 노드 주변 수십 개)만 프레임마다 그린다 (5.6).
                              child: SizedBox.fromSize(
                                size: content.size,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    RepaintBoundary(
                                      child: CustomPaint(
                                        isComplex: true,
                                        painter: _GraphPainter(
                                          signature: Object.hash(labelKey, _motion.liveVersion),
                                          origin: content.topLeft,
                                          positions: positions,
                                          links: drawn,
                                          degree: degree,
                                          docs: docs,
                                          labeled: labeled,
                                          hidden: live,
                                          scale: _lastScale,
                                        ),
                                      ),
                                    ),
                                    RepaintBoundary(
                                      child: CustomPaint(
                                        painter: _MotionPainter(
                                          motion: _motion,
                                          origin: content.topLeft,
                                          positions: positions,
                                          links: liveLinks,
                                          degree: degree,
                                          docs: docs,
                                          labeled: labeled,
                                          scale: _lastScale,
                                        ),
                                      ),
                                    ),
                                  ],
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
                          motion: _motion,
                          origin: content.topLeft,
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
                        _ModeButton(label: '맞추기', isOn: false, onTap: () => _fit(bounds.shift(-content.topLeft), viewport, smooth: true)),
                        const SizedBox(width: 4),
                        // 끌어서 옮긴 노드를 원래 배치로 (5.6). 옮긴 노드가 있을 때만 켜진다.
                        _ModeButton(
                          label: '원래대로',
                          isOn: false,
                          onTap: _motion.hasMoved && !_motion.isResetting ? _reset : null,
                        ),
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
                    right: 330,
                    child: Wrap(
                      key: _chipsKey,
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        _viewToggle(),
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
                        _ModeButton(label: '+', isOn: false, onTap: () => _zoomBy(1.25, viewport.center(Offset.zero))),
                        const SizedBox(height: 4),
                        _ModeButton(label: '−', isOn: false, onTap: () => _zoomBy(0.8, viewport.center(Offset.zero))),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
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
///
/// 끌어서 옮긴 노드([hidden])와 그 연결은 빼고 그린다. 그것은 움직이는 층([_MotionPainter])이 그린다 (설계서_프롬프트이후 5.6).
class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.signature,
    required this.origin,
    required this.positions,
    required this.links,
    required this.degree,
    required this.docs,
    required this.labeled,
    required this.hidden,
    required this.scale,
  });

  /// 그림에 영향을 주는 입력을 묶은 값. 같으면 다시 그리지 않는다 (지도·목록은 빌드마다 새로 만들어져 비교할 수 없음).
  final int signature;
  final Offset origin;
  final Map<String, Point<double>> positions;
  final List<NoteLink> links;
  final Map<String, int> degree;
  final Map<String, IndexedDoc> docs;

  /// 이름표를 다는 노드 ([labeledOf]).
  final Set<String> labeled;

  /// 움직이는 층이 그리는 노드 (여기서는 그리지 않는다).
  final Set<String> hidden;
  final double scale;

  /// 노드가 이 수 이하면 이름표를 모두 단다 (적을 때는 이름이 보여야 무엇인지 안다).
  static const labelAllLimit = 60;

  /// 이보다 많으면 가벼운 그리기로 바꾼다.
  static const manyNodes = 1000;

  /// 노드가 많을 때 이름표를 다는 최대 개수 (연결 많은 순).
  static const labelCap = 150;

  /// 이름표: 적으면 모두, 보통은 허브(확정 연결 2개 이상)·확대 시 전부, 많으면 연결 많은 순 [labelCap]개.
  static Set<String> labeledOf(Map<String, Point<double>> positions, Map<String, int> degree, double scale) {
    if (positions.length <= labelAllLimit) return positions.keys.toSet();
    if (positions.length <= manyNodes) {
      return {for (final id in positions.keys) if ((degree[id] ?? 0) >= 2 || scale > 1.4) id};
    }
    return (positions.keys.toList()..sort((a, b) => (degree[b] ?? 0).compareTo(degree[a] ?? 0))).take(labelCap).toSet();
  }

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
      groups.putIfAbsent(docs[id]?.topicPath ?? '', () => []).add(at(id));
    }
    for (final e in groups.entries) {
      if (e.value.length < 2) continue;
      final c = e.value.reduce((a, b) => a + b) / e.value.length.toDouble();
      final top = e.value.map((o) => o.dy).reduce(min);
      _paintLabel(canvas, e.key, Offset(c.dx, top - 28), const Color(0x99c4b5fd), 14 / scale.clamp(0.6, 2), bold: true);
    }

    final shown = hidden.isEmpty ? positions.keys : positions.keys.where((id) => !hidden.contains(id));
    _paintEdges(
      canvas,
      hidden.isEmpty ? links : links.where((l) => !hidden.contains(l.fromId) && !hidden.contains(l.toId)),
      at,
      docs,
      scale,
      many,
    );
    _paintNodes(canvas, shown, at, degree, docs, scale, many);
    _paintNodeLabels(canvas, shown.where(labeled.contains), at, degree, docs, scale);
  }

  @override
  bool shouldRepaint(_GraphPainter old) => old.signature != signature;
}

/// 연결선: 같은 주제 안은 또렷하게, 주제를 넘는 연결은 흐리게. 모양별로 모아 한 번에 그린다.
void _paintEdges(
  Canvas canvas,
  Iterable<NoteLink> links,
  Offset Function(String) at,
  Map<String, IndexedDoc> docs,
  double scale,
  bool many,
) {
  final paths = <(int, double, bool), Path>{};
  for (final link in links) {
    final a = at(link.fromId);
    final b = at(link.toId);
    final isSameTopic = docs[link.fromId]?.topicPath == docs[link.toId]?.topicPath;
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
}

/// 노드: 빛 번짐(적을 때만) → 원 → 정리 대기 테두리. 원은 진하기별로 모아 그린다.
void _paintNodes(
  Canvas canvas,
  Iterable<String> ids,
  Offset Function(String) at,
  Map<String, int> degree,
  Map<String, IndexedDoc> docs,
  double scale,
  bool many,
) {
  final solid = Path();
  final faint = Path();
  final drafts = Path();
  for (final id in ids) {
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
}

void _paintNodeLabels(
  Canvas canvas,
  Iterable<String> ids,
  Offset Function(String) at,
  Map<String, int> degree,
  Map<String, IndexedDoc> docs,
  double scale,
) {
  for (final id in ids) {
    _paintLabel(
      canvas,
      shortTitle(docs[id]?.title ?? id),
      at(id) + Offset(0, _radius(degree[id] ?? 0) + 10),
      const Color(0xddeae7f7),
      12 / scale.clamp(0.6, 2.5),
      shadow: true,
    );
  }
}

/// 움직이는 층 (설계서_프롬프트이후 5.6): 끌어서 옮긴 노드·따라온 노드와 그 연결만. 바탕과 같은 모양으로 그리고,
/// 끄는 동안 프레임마다 이 층만 다시 그린다 (노드 수십 개 — 바탕 1만 개는 그대로 둔다).
class _MotionPainter extends CustomPainter {
  _MotionPainter({
    required this.motion,
    required this.origin,
    required this.positions,
    required this.links,
    required this.degree,
    required this.docs,
    required this.labeled,
    required this.scale,
  }) : super(repaint: motion);

  final GraphMotion motion;
  final Offset origin;
  final Map<String, Point<double>> positions;

  /// 움직이는 노드에 닿는 연결.
  final List<NoteLink> links;
  final Map<String, int> degree;
  final Map<String, IndexedDoc> docs;
  final Set<String> labeled;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    if (motion.live.isEmpty) return;
    Offset at(String id) {
      final p = motion.moved[id] ?? positions[id]!;
      return Offset(p.x, p.y) - origin;
    }

    final many = positions.length > _GraphPainter.manyNodes;
    final ids = [
      for (final id in motion.live)
        if (positions.containsKey(id)) id,
    ];
    _paintEdges(canvas, links, at, docs, scale, many);
    _paintNodes(canvas, ids, at, degree, docs, scale, many);
    _paintNodeLabels(canvas, ids.where(labeled.contains), at, degree, docs, scale);
  }

  @override
  bool shouldRepaint(_MotionPainter old) =>
      old.positions != positions || old.links != links || old.scale != scale || old.labeled != labeled;
}

/// 노드 위에서 누를 때만 받는 끌기 인식기 (설계서_프롬프트이후 5.6). 빈 곳은 받지 않아 InteractiveViewer가 그래프를 옮긴다.
/// 트랙패드 두 손가락(이동·확대)은 받지 않는다 — 지금처럼 그래프 이동·확대.
class _NodeDragRecognizer extends PanGestureRecognizer {
  _NodeDragRecognizer() : super(debugOwner: null);

  /// 누른 자리(그림 좌표)가 노드 위인가.
  bool Function(Offset local)? canStart;

  @override
  bool isPointerAllowed(PointerEvent event) => super.isPointerAllowed(event) && (canStart?.call(event.localPosition) ?? false);

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) => false;
}

/// 위 층: 고른 노드(마우스를 올린 노드)와 그 연결·이웃만. 그래프 밖(보이는 영역)에 놓고 그래프와 같은 변환을
/// 적용해 그린다. 바탕을 다시 그리지 않으므로 노드가 많아도 가볍다.
class _FocusPainter extends CustomPainter {
  _FocusPainter({
    required this.transform,
    required this.motion,
    required this.origin,
    required this.positions,
    required this.links,
    required this.degree,
    required this.docs,
    required this.focus,
    required this.selected,
    required this.neighbors,
    required this.scale,
  }) : super(repaint: Listenable.merge([transform, motion]));

  /// 그래프 끌기·확대 변환. 이 값이 바뀌면 다시 그린다.
  final TransformationController transform;

  /// 끌어서 옮긴 노드 자리 (노드를 끄는 동안 고른 노드·이웃도 따라 그린다, 5.6).
  final GraphMotion motion;
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
      final p = motion.moved[id] ?? positions[id]!;
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
