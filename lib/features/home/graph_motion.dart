import 'dart:math';
import 'dart:ui' show Offset, Rect;

import 'package:brain_core/brain_core.dart';
import 'package:flutter/foundation.dart';

/// 그물 보기 노드 끌기와 [원래대로] (설계서_프롬프트이후 5.6).
///
/// - 끄는 노드 주변(1~2단계, 최대 [maxNodes]개)만 고무줄(연결 = 용수철)로 따라 움직인다. 나머지 노드는 그대로라
///   노트가 1만 개여도 한 프레임에 셈하는 것은 노드 수십 개다.
/// - 옮긴 자리([moved])는 이 화면에만 있다. graph_layout(저장된 배치)은 건드리지 않아 그래프를 다시 열면 원래 배치다.
/// - [live]: 움직이는 층이 그리는 노드. 바탕 그림은 이 노드와 그 연결을 빼고 그린다 (바탕은 끌기를 시작할 때 한 번만 다시 그림).
class GraphMotion extends ChangeNotifier {
  /// 원래 배치에서 옮겨진 노드의 지금 자리 (그래프 좌표).
  final moved = <String, Point<double>>{};

  /// 움직이는 층이 그리는 노드. 끌기에 한 번 들어온 노드는 [원래대로]·배치가 바뀔 때까지 남는다 ([moved] ⊆ [live]).
  final live = <String>{};

  /// [live]가 바뀔 때마다 오른다 (바탕 그림을 다시 그릴지 가르는 값).
  int liveVersion = 0;

  /// 끌 때 함께 움직이는 노드 수 상한 (끈 노드 포함). 1단계 이웃을 먼저 채우고 남는 자리에 2단계.
  static const maxNodes = 80;

  /// 1단계 이웃 상한. 연결이 수백 개인 허브를 끌어도 [maxNodes] 안에서 2단계까지 조금은 따라오게.
  static const maxFirstHop = 50;

  // 용수철 셈 (초 단위). 끝에 하나만 달린 노드: 고유 진동 √50 ≈ 7rad/s, 감쇠비 약 0.6 → 한 번 살짝 튕기고 1초 안에 멈춘다.
  static const _stiffness = 50.0;
  static const _damping = 8.0;
  static const _minGap = 28.0;
  static const _push = 60.0;

  List<String> _ids = const [];
  Float64List _x = Float64List(0), _y = Float64List(0), _vx = Float64List(0), _vy = Float64List(0);

  // 용수철: _sa → _sb (-1이면 고정점 _fx·_fy), 쉬는 길이 _rest.
  Int32List _sa = Int32List(0), _sb = Int32List(0);
  Float64List _rest = Float64List(0), _fx = Float64List(0), _fy = Float64List(0);
  bool _isDragging = false;
  double _sinceRelease = 0;
  Rect _area = Rect.largest;

  Map<String, Point<double>>? _resetFrom;
  Map<String, Point<double>> _resetTo = const {};

  /// 용수철 셈이 도는 중 (끄는 중이거나 놓은 뒤 자리 잡는 중).
  bool get isSimulating => _ids.isNotEmpty;

  /// 끄는 중인 노드.
  String? get dragging => _isDragging && _ids.isNotEmpty ? _ids.first : null;

  bool get isResetting => _resetFrom != null;

  /// 옮긴 노드가 있다 ([원래대로]를 켠다).
  bool get hasMoved => live.isNotEmpty;

  /// [id] 노드 끌기 시작. [positions]는 지금 보이는 노드의 원래 자리, [links]는 그려진 연결.
  /// [springs]가 false(움직임 줄이기)면 끈 노드만 움직인다. [live]가 늘었으면 true (바탕을 다시 그려야 함).
  bool begin(
    String id,
    Map<String, Point<double>> positions,
    List<NoteLink> links, {
    required bool springs,
    required Rect area,
  }) {
    _area = area;
    // 1단계·2단계 이웃: 연결 목록을 두 번 훑는다 (인접 목록을 만들지 않아 1만 개에서도 몇 ms).
    final group = <String>{id};
    if (springs) {
      for (final l in links) {
        if (group.length > maxFirstHop) break;
        final other = l.fromId == id ? l.toId : (l.toId == id ? l.fromId : null);
        if (other != null && positions.containsKey(other)) group.add(other);
      }
      final first = group.toSet();
      for (final l in links) {
        if (group.length >= maxNodes) break;
        final a = first.contains(l.fromId), b = first.contains(l.toId);
        if (a == b) continue;
        final other = a ? l.toId : l.fromId;
        if (positions.containsKey(other)) group.add(other);
      }
    }
    _ids = group.toList();
    final index = {for (var i = 0; i < _ids.length; i++) _ids[i]: i};
    final n = _ids.length;
    _x = Float64List(n);
    _y = Float64List(n);
    _vx = Float64List(n);
    _vy = Float64List(n);
    Point<double> now(String id) => moved[id] ?? positions[id]!;
    for (var i = 0; i < n; i++) {
      final p = now(_ids[i]);
      _x[i] = p.x;
      _y[i] = p.y;
    }
    // 용수철: 무리 안 노드에 닿는 연결 (다른 쪽이 무리 밖이면 그 자리에 고정). 쉬는 길이는 지금 길이.
    final sa = <int>[], sb = <int>[], rest = <double>[], fx = <double>[], fy = <double>[];
    final seen = <(String, String)>{};
    if (n > 1) {
      for (final l in links) {
        var a = index[l.fromId], b = index[l.toId];
        if (a == null && b == null) continue;
        if (l.fromId == l.toId || !positions.containsKey(l.fromId) || !positions.containsKey(l.toId)) continue;
        final key = l.fromId.compareTo(l.toId) < 0 ? (l.fromId, l.toId) : (l.toId, l.fromId);
        if (!seen.add(key)) continue;
        var otherId = l.toId;
        if (a == null) {
          a = b;
          b = null;
          otherId = l.fromId;
        }
        final pb = b == null ? now(otherId) : Point(_x[b], _y[b]);
        sa.add(a!);
        sb.add(b ?? -1);
        fx.add(pb.x);
        fy.add(pb.y);
        rest.add(max(24.0, sqrt(pow(_x[a] - pb.x, 2) + pow(_y[a] - pb.y, 2))));
      }
    }
    _sa = Int32List.fromList(sa);
    _sb = Int32List.fromList(sb);
    _rest = Float64List.fromList(rest);
    _fx = Float64List.fromList(fx);
    _fy = Float64List.fromList(fy);
    _isDragging = true;
    _sinceRelease = 0;
    final before = live.length;
    live.addAll(_ids);
    if (live.length != before) liveVersion++;
    return live.length != before;
  }

  /// 끄는 노드를 [to]로 (영역 안으로 자른다: 그림 밖으로 나가면 다시 잡을 수 없다).
  void dragTo(Offset to) {
    if (_ids.isEmpty) return;
    _x[0] = to.dx.clamp(_area.left, _area.right);
    _y[0] = to.dy.clamp(_area.top, _area.bottom);
    moved[_ids.first] = Point(_x[0], _y[0]);
    notifyListeners();
  }

  /// 손을 뗐다: 끈 노드는 그 자리에 머물고, 따라오던 노드는 자리를 잡을 때까지 조금 더 움직인다.
  void release() {
    _isDragging = false;
    _sinceRelease = 0;
  }

  /// [dt]초만큼 셈한다. 아직 움직이면 true.
  bool step(double dt) {
    final n = _ids.length;
    if (n == 0) return false;
    if (n == 1) {
      if (!_isDragging) _ids = const [];
      return _isDragging;
    }
    dt = dt.clamp(0, 1 / 20);
    final steps = max(1, (dt * 120).ceil());
    final h = dt / steps;
    final ax = Float64List(n), ay = Float64List(n);
    for (var s = 0; s < steps; s++) {
      ax.fillRange(0, n, 0);
      ay.fillRange(0, n, 0);
      for (var e = 0; e < _sa.length; e++) {
        final a = _sa[e], b = _sb[e];
        final bx = b < 0 ? _fx[e] : _x[b], by = b < 0 ? _fy[e] : _y[b];
        final dx = bx - _x[a], dy = by - _y[a];
        final d = sqrt(dx * dx + dy * dy);
        if (d < 1e-6) continue;
        final f = _stiffness * (d - _rest[e]) / d;
        ax[a] += f * dx;
        ay[a] += f * dy;
        if (b >= 0) {
          ax[b] -= f * dx;
          ay[b] -= f * dy;
        }
      }
      // 따라오는 노드끼리 한 점에 겹치지 않게 가까우면 민다.
      for (var i = 0; i < n; i++) {
        for (var j = i + 1; j < n; j++) {
          final dx = _x[j] - _x[i], dy = _y[j] - _y[i];
          final d2 = dx * dx + dy * dy;
          if (d2 >= _minGap * _minGap) continue;
          final d = max(sqrt(d2), 0.5);
          final f = _push * (_minGap - d) / d;
          ax[i] -= f * dx;
          ay[i] -= f * dy;
          ax[j] += f * dx;
          ay[j] += f * dy;
        }
      }
      final keep = exp(-_damping * h);
      for (var i = 1; i < n; i++) {
        // 0번(끄는·끈 노드)은 손이 정한 자리에 고정
        _vx[i] = (_vx[i] + ax[i] * h) * keep;
        _vy[i] = (_vy[i] + ay[i] * h) * keep;
        _x[i] = (_x[i] + _vx[i] * h).clamp(_area.left, _area.right);
        _y[i] = (_y[i] + _vy[i] * h).clamp(_area.top, _area.bottom);
      }
    }
    var fastest = 0.0;
    for (var i = 1; i < n; i++) {
      moved[_ids[i]] = Point(_x[i], _y[i]);
      fastest = max(fastest, _vx[i] * _vx[i] + _vy[i] * _vy[i]);
    }
    notifyListeners();
    if (_isDragging) return true;
    _sinceRelease += dt;
    // 초속 2 이하로 느려지거나 놓은 지 3초가 지나면 그 자리에 둔다.
    if (fastest < 4 || _sinceRelease > 3) {
      _ids = const [];
      return false;
    }
    return true;
  }

  /// [원래대로] 시작: 옮긴 노드를 [original] 자리로 되돌릴 준비 (셈은 멈춘다).
  void startReset(Map<String, Point<double>> original) {
    _ids = const [];
    _isDragging = false;
    _resetFrom = Map.of(moved);
    _resetTo = original;
  }

  /// [원래대로] 중간: t(0~1)만큼 원래 자리 쪽으로.
  void resetTick(double t) {
    final from = _resetFrom;
    if (from == null) return;
    for (final e in from.entries) {
      final to = _resetTo[e.key];
      if (to == null) continue;
      moved[e.key] = Point(e.value.x + (to.x - e.value.x) * t, e.value.y + (to.y - e.value.y) * t);
    }
    notifyListeners();
  }

  /// 모두 원래 배치로 (옮긴 자리·움직이는 층 비움). [notify]가 false면 알리지 않는다 (빌드 중).
  void clear({bool notify = true}) {
    _ids = const [];
    _isDragging = false;
    _resetFrom = null;
    _resetTo = const {};
    moved.clear();
    if (live.isNotEmpty) {
      live.clear();
      liveVersion++;
    }
    if (notify) notifyListeners();
  }
}
