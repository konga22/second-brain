import 'dart:math';

/// 그래프 노드 하나: id와 주제(같은 주제끼리 모인다).
class GraphNode {
  const GraphNode(this.id, this.group);

  final String id;
  final String group;
}

class GraphEdge {
  const GraphEdge(this.from, this.to, {this.weight = 1});

  final String from;
  final String to;

  /// 추천 연결은 약하게(0.5) 당긴다.
  final double weight;
}

/// force 배치 (설계서 5.5): 밀어내는 힘(Barnes–Hut 근사) + 연결선 당기는 힘 + 주제 중심 당기는 힘.
///
/// 모든 노드 쌍을 계산하면 노드 1만 개에서 반복 1번에 약 5천만 쌍이라, 사분 트리로 먼 노드 묶음을
/// 하나로 보고 계산한다(θ = 0.8). 결과는 같은 입력이면 같다(난수 씨앗 고정).
/// [initial]에 위치가 있는 노드는 그 자리에서 시작해, 새 노드만 자리를 잡도록 반복을 줄인다.
Map<String, Point<double>> forceLayout(
  List<GraphNode> nodes,
  List<GraphEdge> edges, {
  Map<String, Point<double>> initial = const {},
  int iterations = 300,
  double theta = 0.8,
}) {
  if (nodes.isEmpty) return const {};
  // 모든 노드에 저장된 자리가 있으면 다시 계산하지 않는다 (그래프 첫 표시 1초 목표).
  if (nodes.every((n) => initial.containsKey(n.id))) {
    return {for (final n in nodes) n.id: initial[n.id]!};
  }
  final random = Random(42);
  final index = {for (final (i, n) in nodes.indexed) n.id: i};
  final groups = {for (final n in nodes) n.group}.toList()..sort();
  final spread = sqrt(nodes.length) * 60;
  final groupCenter = <String, Point<double>>{
    for (final (i, g) in groups.indexed)
      g: groups.length == 1
          ? const Point(0, 0)
          : Point(
              cos(2 * pi * i / groups.length) * spread * 0.6,
              sin(2 * pi * i / groups.length) * spread * 0.6,
            ),
  };
  final xs = List<double>.filled(nodes.length, 0);
  final ys = List<double>.filled(nodes.length, 0);
  var known = 0;
  for (final (i, n) in nodes.indexed) {
    final start = initial[n.id];
    if (start != null) {
      xs[i] = start.x;
      ys[i] = start.y;
      known++;
    } else {
      final c = groupCenter[n.group]!;
      xs[i] = c.x + (random.nextDouble() - 0.5) * 80;
      ys[i] = c.y + (random.nextDouble() - 0.5) * 80;
    }
  }
  // 대부분 자리가 있으면 새 노드만 맞추면 되므로 적게 돈다.
  final steps = known > nodes.length * 0.8 ? min(iterations, 60) : iterations;
  final links = [
    for (final e in edges)
      if (index[e.from] != null && index[e.to] != null && e.from != e.to)
        (index[e.from]!, index[e.to]!, e.weight),
  ];
  const repulsion = 2400.0;
  const springLength = 70.0;
  const springK = 0.04;
  const groupK = 0.03; // 같은 주제끼리 또렷이 모이게 (11/07 사용자 의견: 뒤죽박죽)
  var temperature = spread * 0.1 + 20;
  final dx = List<double>.filled(nodes.length, 0);
  final dy = List<double>.filled(nodes.length, 0);

  for (var step = 0; step < steps; step++) {
    dx.fillRange(0, dx.length, 0);
    dy.fillRange(0, dy.length, 0);
    final tree = _QuadTree.build(xs, ys);
    for (var i = 0; i < nodes.length; i++) {
      final (fx, fy) = tree.force(i, xs[i], ys[i], theta, repulsion);
      dx[i] += fx;
      dy[i] += fy;
    }
    for (final (a, b, w) in links) {
      final ddx = xs[b] - xs[a];
      final ddy = ys[b] - ys[a];
      final dist = sqrt(ddx * ddx + ddy * ddy) + 0.01;
      final f = springK * w * (dist - springLength);
      dx[a] += f * ddx / dist;
      dy[a] += f * ddy / dist;
      dx[b] -= f * ddx / dist;
      dy[b] -= f * ddy / dist;
    }
    for (var i = 0; i < nodes.length; i++) {
      final c = groupCenter[nodes[i].group]!;
      dx[i] += (c.x - xs[i]) * groupK;
      dy[i] += (c.y - ys[i]) * groupK;
      final len = sqrt(dx[i] * dx[i] + dy[i] * dy[i]);
      if (len > temperature) {
        dx[i] *= temperature / len;
        dy[i] *= temperature / len;
      }
      xs[i] += dx[i];
      ys[i] += dy[i];
    }
    temperature *= 0.985;
  }
  return {
    for (final (i, n) in nodes.indexed) n.id: Point(xs[i], ys[i]),
  };
}

/// Barnes–Hut 사분 트리. 칸의 크기/거리 < θ 이면 칸 안 노드를 질량 중심 하나로 본다.
class _QuadTree {
  _QuadTree(this.x0, this.y0, this.size);

  final double x0;
  final double y0;
  final double size;
  double mass = 0;
  double cx = 0;
  double cy = 0;
  int? point;
  List<_QuadTree>? children;

  static _QuadTree build(List<double> xs, List<double> ys) {
    var minX = xs.first, maxX = xs.first, minY = ys.first, maxY = ys.first;
    for (var i = 1; i < xs.length; i++) {
      minX = min(minX, xs[i]);
      maxX = max(maxX, xs[i]);
      minY = min(minY, ys[i]);
      maxY = max(maxY, ys[i]);
    }
    final size = max(maxX - minX, maxY - minY) + 1;
    final root = _QuadTree(minX, minY, size);
    for (var i = 0; i < xs.length; i++) {
      root._insert(i, xs[i], ys[i], xs, ys, 0);
    }
    return root;
  }

  void _insert(int i, double x, double y, List<double> xs, List<double> ys, int depth) {
    cx = (cx * mass + x) / (mass + 1);
    cy = (cy * mass + y) / (mass + 1);
    mass += 1;
    if (children == null && point == null) {
      point = i;
      return;
    }
    if (depth > 40) return; // 같은 자리에 겹친 노드는 더 나누지 않는다
    if (children == null) {
      final half = size / 2;
      children = [
        _QuadTree(x0, y0, half),
        _QuadTree(x0 + half, y0, half),
        _QuadTree(x0, y0 + half, half),
        _QuadTree(x0 + half, y0 + half, half),
      ];
      final old = point!;
      point = null;
      _child(xs[old], ys[old])._insert(old, xs[old], ys[old], xs, ys, depth + 1);
    }
    _child(x, y)._insert(i, x, y, xs, ys, depth + 1);
  }

  _QuadTree _child(double x, double y) {
    final half = size / 2;
    final right = x >= x0 + half ? 1 : 0;
    final bottom = y >= y0 + half ? 2 : 0;
    return children![right + bottom];
  }

  (double, double) force(int i, double x, double y, double theta, double k) {
    if (mass == 0 || point == i && children == null) return (0, 0);
    var ddx = x - cx;
    var ddy = y - cy;
    var dist2 = ddx * ddx + ddy * ddy;
    if (dist2 < 0.01) {
      // 같은 자리: 조금 흔들어 떼어 놓는다
      ddx = (i % 7 - 3) * 0.1 + 0.05;
      ddy = (i % 5 - 2) * 0.1 + 0.05;
      dist2 = ddx * ddx + ddy * ddy;
    }
    if (children == null || size * size / dist2 < theta * theta) {
      final f = k * mass / dist2;
      final dist = sqrt(dist2);
      return (f * ddx / dist, f * ddy / dist);
    }
    var fx = 0.0, fy = 0.0;
    for (final child in children!) {
      final (cfx, cfy) = child.force(i, x, y, theta, k);
      fx += cfx;
      fy += cfy;
    }
    return (fx, fy);
  }
}
