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
///
/// [legacyGroupRing]은 주제 중심을 이름순으로 원 위에 두던 예전 방식이다. 새 방식과 견주는 시험·측정에만 쓴다.
Map<String, Point<double>> forceLayout(
  List<GraphNode> nodes,
  List<GraphEdge> edges, {
  Map<String, Point<double>> initial = const {},
  int iterations = 300,
  double theta = 0.8,
  bool legacyGroupRing = false,
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
  final links = [
    for (final e in edges)
      if (index[e.from] != null && index[e.to] != null && e.from != e.to)
        (index[e.from]!, index[e.to]!, e.weight),
  ];
  final groupCenter = legacyGroupRing
      ? <String, Point<double>>{
          for (final (i, g) in groups.indexed)
            g: groups.length == 1
                ? const Point(0, 0)
                : Point(
                    cos(2 * pi * i / groups.length) * spread * 0.6,
                    sin(2 * pi * i / groups.length) * spread * 0.6,
                  ),
        }
      : _groupCenters(nodes, links, groups);
  final groupSize = <String, int>{};
  for (final n in nodes) {
    groupSize[n.group] = (groupSize[n.group] ?? 0) + 1;
  }
  final xs = List<double>.filled(nodes.length, 0);
  final ys = List<double>.filled(nodes.length, 0);
  var known = 0;
  for (final (i, n) in nodes.indexed) {
    final start = initial[n.id];
    if (start != null) {
      xs[i] = start.x;
      ys[i] = start.y;
      known++;
    } else if (legacyGroupRing) {
      final c = groupCenter[n.group]!;
      xs[i] = c.x + (random.nextDouble() - 0.5) * 80;
      ys[i] = c.y + (random.nextDouble() - 0.5) * 80;
    } else {
      // 주제 크기만 한 원 안에 고르게 뿌린다. 한 점에 뭉쳐 시작하면 앞쪽 반복이 퍼지는 데만 쓰인다.
      final c = groupCenter[n.group]!;
      final r = _groupRadius(groupSize[n.group]!) * 0.5 * sqrt(random.nextDouble());
      final a = random.nextDouble() * 2 * pi;
      xs[i] = c.x + r * cos(a);
      ys[i] = c.y + r * sin(a);
    }
  }
  // 새 노드가 조금이면(노트 몇 개 추가) 기존 노드는 그 자리에 두고 새 노드만 자리를 잡는다.
  // 전체를 다시 돌리면 노드 1만 개에서 2.4초 걸리고 기존 노드도 조금씩 움직여 화면이 흔들린다 (11/07 측정).
  final fresh = [for (final (i, n) in nodes.indexed) if (!initial.containsKey(n.id)) i];
  if (known > 0 && fresh.length <= max(50, nodes.length ~/ 20)) {
    _placeNew(nodes, fresh, xs, ys, links, random);
    return {for (final (i, n) in nodes.indexed) n.id: Point(xs[i], ys[i])};
  }
  // 대부분 자리가 있으면 새 노드만 맞추면 되므로 적게 돈다.
  final steps = known > nodes.length * 0.8 ? min(iterations, 60) : iterations;
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
  // 힘의 균형만으로는 촘촘한 무리 안에서 노드가 겹칠 수 있다. 마지막에 겹친 것만 뗀다.
  if (!legacyGroupRing) _separate(xs, ys);
  return {
    for (final (i, n) in nodes.indexed) n.id: Point(xs[i], ys[i]),
  };
}

/// 주제 무리 하나가 차지하는 원의 반지름 어림 (노드 사이 약 45px).
double _groupRadius(int size) => 22 * sqrt(size) + 30;

/// 주제 중심 (설계서 5.5 v1.3.28). 주제를 한 덩어리로 보고 작은 force 배치를 한다.
///
/// 예전에는 주제를 이름순으로 원 위에 놓았다. 서로 연결이 많은 주제가 원의 반대편에 놓이면 주제 사이
/// 선이 화면 한가운데를 가로질러 꼬여 보였다 (11/11 사용자 지적). 여기서는 연결이 많은 주제끼리 당기고,
/// 큰 주제는 자리를 넓게 받고, 서로 겹치지 않게 민다. 난수를 쓰지 않아 같은 입력이면 같은 결과다.
Map<String, Point<double>> _groupCenters(
  List<GraphNode> nodes,
  List<(int, int, double)> links,
  List<String> groups,
) {
  final count = groups.length;
  if (count == 1) return {groups.first: const Point(0, 0)};
  final at = {for (final (i, g) in groups.indexed) g: i};
  final size = List<int>.filled(count, 0);
  for (final n in nodes) {
    size[at[n.group]!]++;
  }
  final radius = [for (final s in size) _groupRadius(s)];
  // 주제 사이 연결 무게
  final weight = <(int, int), double>{};
  var maxWeight = 0.0;
  for (final (a, b, w) in links) {
    final ga = at[nodes[a].group]!, gb = at[nodes[b].group]!;
    if (ga == gb) continue;
    final key = ga < gb ? (ga, gb) : (gb, ga);
    final sum = (weight[key] ?? 0) + w;
    weight[key] = sum;
    if (sum > maxWeight) maxWeight = sum;
  }
  // force 배치는 시작 자리에 따라 덜 좋은 모양에 멈출 수 있다. 시작 순서를 세 가지로 해 보고 가장 좋은 것을 쓴다:
  // 이름순, 연결이 많은 주제부터, 가장 강하게 이어진 주제를 따라가는 순서.
  final total = List<double>.filled(count, 0);
  for (final e in weight.entries) {
    total[e.key.$1] += e.value;
    total[e.key.$2] += e.value;
  }
  final byWeight = [for (var i = 0; i < count; i++) i]
    ..sort((a, b) => total[b] != total[a] ? total[b].compareTo(total[a]) : a.compareTo(b));
  final chain = <int>[byWeight.first];
  final left = {...byWeight.skip(1)};
  while (left.isNotEmpty) {
    final last = chain.last;
    var next = -1;
    var best = -1.0;
    for (final g in byWeight) {
      if (!left.contains(g)) continue;
      final w = weight[last < g ? (last, g) : (g, last)] ?? 0;
      if (w > best) {
        best = w;
        next = g;
      }
    }
    chain.add(next);
    left.remove(next);
  }
  (List<double>, List<double>)? bestLayout;
  var bestScore = double.infinity;
  for (final order in [[for (var i = 0; i < count; i++) i], byWeight, chain]) {
    final (xs, ys) = _relaxGroups(order, radius, weight, maxWeight);
    final score = _groupScore(xs, ys, radius, weight, maxWeight);
    if (score < bestScore) {
      bestScore = score;
      bestLayout = (xs, ys);
    }
  }
  final (xs, ys) = bestLayout!;
  // 가장 길게 퍼진 방향이 가로가 되게 돌린다 (주제 크기를 무게로 한 주축).
  var sxx = 0.0, syy = 0.0, sxy = 0.0, mx = 0.0, my = 0.0, mass = 0.0;
  for (var i = 0; i < count; i++) {
    mx += xs[i] * size[i];
    my += ys[i] * size[i];
    mass += size[i];
  }
  mx /= mass;
  my /= mass;
  for (var i = 0; i < count; i++) {
    final x = xs[i] - mx, y = ys[i] - my;
    sxx += x * x * size[i];
    syy += y * y * size[i];
    sxy += x * y * size[i];
  }
  final angle = 0.5 * atan2(2 * sxy, sxx - syy);
  final c = cos(-angle), s = sin(-angle);
  return {
    for (final (i, g) in groups.indexed)
      g: Point((xs[i] - mx) * c - (ys[i] - my) * s, (xs[i] - mx) * s + (ys[i] - my) * c),
  };
}

/// 주제 배치의 점수 (낮을수록 좋다): 주제 사이 연결끼리 가로지르는 정도 + 연결된 주제 사이 거리.
double _groupScore(
  List<double> xs,
  List<double> ys,
  List<double> radius,
  Map<(int, int), double> weight,
  double maxWeight,
) {
  if (weight.isEmpty) return 0;
  final pairs = weight.entries.toList();
  var length = 0.0;
  for (final e in pairs) {
    final (a, b) = e.key;
    final d = sqrt(pow(xs[a] - xs[b], 2) + pow(ys[a] - ys[b], 2));
    length += e.value / maxWeight * d / (radius[a] + radius[b]);
  }
  var crossing = 0.0;
  if (pairs.length <= 600) {
    double cross(int o, int a, int b) => (xs[a] - xs[o]) * (ys[b] - ys[o]) - (ys[a] - ys[o]) * (xs[b] - xs[o]);
    for (var i = 0; i < pairs.length; i++) {
      final (a, b) = pairs[i].key;
      for (var j = i + 1; j < pairs.length; j++) {
        final (c, d) = pairs[j].key;
        if (a == c || a == d || b == c || b == d) continue;
        if (cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0) {
          crossing += pairs[i].value * pairs[j].value / (maxWeight * maxWeight);
        }
      }
    }
  }
  return crossing * 10 + length;
}

/// 주제 중심들을 [order] 순서로 원 위에 놓고 시작해 힘으로 자리를 잡는다.
(List<double>, List<double>) _relaxGroups(
  List<int> order,
  List<double> radius,
  Map<(int, int), double> weight,
  double maxWeight,
) {
  final count = radius.length;
  // 모든 원이 들어갈 만큼 큰 원 위에서 시작한다.
  final ring = max(radius.reduce((a, b) => a + b) / pi, 120.0);
  final xs = List<double>.filled(count, 0), ys = List<double>.filled(count, 0);
  for (final (slot, g) in order.indexed) {
    xs[g] = cos(2 * pi * slot / count) * ring;
    ys[g] = sin(2 * pi * slot / count) * ring;
  }
  const gap = 40.0;
  var temperature = ring * 0.25 + 20;
  final dx = List<double>.filled(count, 0), dy = List<double>.filled(count, 0);
  for (var step = 0; step < 400; step++) {
    dx.fillRange(0, count, 0);
    dy.fillRange(0, count, 0);
    for (var i = 0; i < count; i++) {
      for (var j = i + 1; j < count; j++) {
        var ddx = xs[j] - xs[i], ddy = ys[j] - ys[i];
        var dist = sqrt(ddx * ddx + ddy * ddy);
        if (dist < 0.01) {
          ddx = 1;
          ddy = 0;
          dist = 1;
        }
        final rest = radius[i] + radius[j] + gap;
        // 겹치면 세게 떼고, 떨어져 있으면 약하게 민다.
        var push = 30 * radius[i] * radius[j] / (dist * dist);
        if (dist < rest) push += (rest - dist) * 0.5;
        // 연결된 주제끼리는 맞닿을 때까지 당긴다.
        final w = weight[(i, j)];
        if (w != null && dist > rest) push -= 0.08 * (0.3 + 0.7 * w / maxWeight) * (dist - rest);
        dx[i] -= push * ddx / dist;
        dy[i] -= push * ddy / dist;
        dx[j] += push * ddx / dist;
        dy[j] += push * ddy / dist;
      }
    }
    for (var i = 0; i < count; i++) {
      // 연결이 없는 주제가 멀리 떠나지 않게 가운데로 약하게 당긴다. 그래프 영역은 가로로 넓으므로
      // 위아래를 더 세게 당겨 가로로 퍼지게 한다 (세로로 길면 화면에 맞출 때 작아지고 위 도구 줄에 가린다).
      dx[i] -= xs[i] * 0.012;
      dy[i] -= ys[i] * 0.032;
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
  return (xs, ys);
}

/// 겹친 노드를 뗀다: 거리 [minDist] 안의 쌍을 서로 밀어낸다.
/// 격자에 담아 가까운 칸만 보므로 노드가 많아도 빠르다. 난수를 쓰지 않는다.
void _separate(List<double> xs, List<double> ys, {double minDist = 34, int passes = 8}) {
  final count = xs.length;
  for (var pass = 0; pass < passes; pass++) {
    final grid = <(int, int), List<int>>{};
    for (var i = 0; i < count; i++) {
      grid.putIfAbsent(((xs[i] / minDist).floor(), (ys[i] / minDist).floor()), () => []).add(i);
    }
    var moved = false;
    for (var i = 0; i < count; i++) {
      final cx = (xs[i] / minDist).floor(), cy = (ys[i] / minDist).floor();
      for (var gx = cx - 1; gx <= cx + 1; gx++) {
        for (var gy = cy - 1; gy <= cy + 1; gy++) {
          for (final j in grid[(gx, gy)] ?? const <int>[]) {
            if (j <= i) continue;
            var ddx = xs[j] - xs[i], ddy = ys[j] - ys[i];
            var dist = sqrt(ddx * ddx + ddy * ddy);
            if (dist >= minDist) continue;
            if (dist < 0.01) {
              // 같은 자리: 번호로 방향을 정해 뗀다
              ddx = cos(i * 2.399963);
              ddy = sin(i * 2.399963);
              dist = 1;
            }
            final push = (minDist - dist) / 2;
            xs[i] -= push * ddx / dist;
            ys[i] -= push * ddy / dist;
            xs[j] += push * ddx / dist;
            ys[j] += push * ddy / dist;
            moved = true;
          }
        }
      }
    }
    if (!moved) break;
  }
}

/// 새 노드만 자리 잡기: 이웃(연결된 기존 노드)의 가운데, 없으면 같은 주제 노드들의 가운데 근처에 두고,
/// 기존 노드는 고정한 채 새 노드에만 힘을 준다 (밀어내기는 기존 노드 사분 트리를 한 번만 만들어 쓴다).
void _placeNew(
  List<GraphNode> nodes,
  List<int> fresh,
  List<double> xs,
  List<double> ys,
  List<(int, int, double)> links,
  Random random,
) {
  final isFresh = List<bool>.filled(nodes.length, false);
  for (final i in fresh) {
    isFresh[i] = true;
  }
  // 주제별 실제 가운데 (기존 배치 기준)
  final sum = <String, (double, double, int)>{};
  var allX = 0.0, allY = 0.0, allN = 0;
  for (var i = 0; i < nodes.length; i++) {
    if (isFresh[i]) continue;
    final (sx, sy, n) = sum[nodes[i].group] ?? (0.0, 0.0, 0);
    sum[nodes[i].group] = (sx + xs[i], sy + ys[i], n + 1);
    allX += xs[i];
    allY += ys[i];
    allN++;
  }
  Point<double> center(String group) {
    final g = sum[group];
    return g == null ? Point(allX / allN, allY / allN) : Point(g.$1 / g.$3, g.$2 / g.$3);
  }

  final neighbors = <int, List<int>>{};
  for (final (a, b, _) in links) {
    if (isFresh[a]) neighbors.putIfAbsent(a, () => []).add(b);
    if (isFresh[b]) neighbors.putIfAbsent(b, () => []).add(a);
  }
  for (final i in fresh) {
    final known = [for (final j in neighbors[i] ?? const <int>[]) if (!isFresh[j]) j];
    final Point<double> c = known.isEmpty
        ? center(nodes[i].group)
        : Point(
            known.map((j) => xs[j]).reduce((a, b) => a + b) / known.length,
            known.map((j) => ys[j]).reduce((a, b) => a + b) / known.length,
          );
    xs[i] = c.x + (random.nextDouble() - 0.5) * 60;
    ys[i] = c.y + (random.nextDouble() - 0.5) * 60;
  }
  // 기존 노드만으로 사분 트리를 만든다 (기존 노드는 움직이지 않으므로 한 번이면 된다).
  final fixedX = <double>[], fixedY = <double>[];
  for (var i = 0; i < nodes.length; i++) {
    if (!isFresh[i]) {
      fixedX.add(xs[i]);
      fixedY.add(ys[i]);
    }
  }
  final tree = _QuadTree.build(fixedX, fixedY);
  const repulsion = 2400.0, springLength = 70.0, springK = 0.04, groupK = 0.03;
  var temperature = 40.0;
  for (var step = 0; step < 80; step++) {
    for (final i in fresh) {
      // 음수 번호: 트리 밖 노드라 자기 자신을 빼지 않는다. 노드마다 다른 수라 기존 노드와 겹쳐도 떼는 방향이 다르다.
      var (fx, fy) = tree.force(-1 - i, xs[i], ys[i], 0.8, repulsion);
      for (final j in fresh) {
        if (j == i) continue;
        final ddx = xs[i] - xs[j], ddy = ys[i] - ys[j];
        final d2 = ddx * ddx + ddy * ddy + 0.01;
        final f = repulsion / d2, d = sqrt(d2);
        fx += f * ddx / d;
        fy += f * ddy / d;
      }
      for (final j in neighbors[i] ?? const <int>[]) {
        final ddx = xs[j] - xs[i], ddy = ys[j] - ys[i];
        final d = sqrt(ddx * ddx + ddy * ddy) + 0.01;
        final f = springK * (d - springLength);
        fx += f * ddx / d;
        fy += f * ddy / d;
      }
      final c = center(nodes[i].group);
      fx += (c.x - xs[i]) * groupK;
      fy += (c.y - ys[i]) * groupK;
      final len = sqrt(fx * fx + fy * fy);
      if (len > temperature) {
        fx *= temperature / len;
        fy *= temperature / len;
      }
      xs[i] += fx;
      ys[i] += fy;
    }
    temperature *= 0.96;
  }
  // 새 노드가 기존 노드 위에 겹쳐 놓이지 않게 새 노드만 뗀다 (기존 노드는 그대로).
  _separateFresh(xs, ys, fresh, isFresh);
}

/// 새 노드만 움직여 겹침을 뗀다. 기존 노드는 움직이지 않으므로 격자를 한 번만 만든다
/// (노드 1만 개에서 격자를 번번이 다시 만들면 새 노드 1개에 100ms가 더 든다).
void _separateFresh(List<double> xs, List<double> ys, List<int> fresh, List<bool> isFresh, {double minDist = 34}) {
  final grid = <(int, int), List<int>>{};
  for (var i = 0; i < xs.length; i++) {
    if (isFresh[i]) continue;
    grid.putIfAbsent(((xs[i] / minDist).floor(), (ys[i] / minDist).floor()), () => []).add(i);
  }
  for (var pass = 0; pass < 8; pass++) {
    var moved = false;
    for (final i in fresh) {
      void pushFrom(int j, double share) {
        var ddx = xs[i] - xs[j], ddy = ys[i] - ys[j];
        var dist = sqrt(ddx * ddx + ddy * ddy);
        if (dist >= minDist) return;
        if (dist < 0.01) {
          ddx = cos(i * 2.399963);
          ddy = sin(i * 2.399963);
          dist = 1;
        }
        xs[i] += (minDist - dist) * share * ddx / dist;
        ys[i] += (minDist - dist) * share * ddy / dist;
        moved = true;
      }

      final cx = (xs[i] / minDist).floor(), cy = (ys[i] / minDist).floor();
      for (var gx = cx - 1; gx <= cx + 1; gx++) {
        for (var gy = cy - 1; gy <= cy + 1; gy++) {
          for (final j in grid[(gx, gy)] ?? const <int>[]) {
            pushFrom(j, 1);
          }
        }
      }
      for (final j in fresh) {
        if (j != i) pushFrom(j, 0.5);
      }
    }
    if (!moved) break;
  }
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

  bool _contains(double x, double y) => x >= x0 && x < x0 + size && y >= y0 && y < y0 + size;

  /// 노드 [i]가 (x, y)에서 받는 밀어내는 힘. [i]가 음수면 트리 밖의 노드다 (자기 자신을 뺄 필요가 없다).
  (double, double) force(int i, double x, double y, double theta, double k) {
    if (mass == 0) return (0, 0);
    // 자기 자신이 든 칸은 한 덩어리로 보지 않고 안으로 내려간다. 예전에는 자기 질량까지 넣어 계산해, 두 노드가
    // 0.1 안으로 겹치면 둘 다 자기 칸에 밀려 같은 쪽으로 최대 걸음만큼 날아갔다 (설계서 5.5 / 설계서_프롬프트이후 5.6, 11/14:
    // 노트 1만 개에서 n_06381·n_09710이 무리보다 1,230 위로 떨어짐).
    final isSelf = i >= 0 && _contains(x, y);
    if (children != null && isSelf) return _childForce(i, x, y, theta, k);
    // 끝 칸에는 같은 자리에 겹친 노드가 여럿 들어 있을 수 있다 (깊이 40 넘으면 더 나누지 않음). 자기 몫만 뺀다.
    final others = children == null && isSelf ? mass - 1 : mass;
    if (others <= 0) return (0, 0);
    var ddx = x - cx;
    var ddy = y - cy;
    var dist2 = ddx * ddx + ddy * ddy;
    if (dist2 < 0.01) {
      // 같은 자리: 노드마다 다른 방향(황금각)으로 뗀다. 예전처럼 번호 % 7·% 5로 정하면 번호가 35 차이 나는
      // 노드끼리 방향이 같아 떨어지지 않고 함께 밀려 갔다 (11/14).
      ddx = cos(i * 2.399963) * 0.1;
      ddy = sin(i * 2.399963) * 0.1;
      dist2 = 0.01;
    }
    if (children == null || size * size / dist2 < theta * theta) {
      final f = k * others / dist2;
      final dist = sqrt(dist2);
      return (f * ddx / dist, f * ddy / dist);
    }
    return _childForce(i, x, y, theta, k);
  }

  (double, double) _childForce(int i, double x, double y, double theta, double k) {
    var fx = 0.0, fy = 0.0;
    for (final child in children!) {
      final (cfx, cfy) = child.force(i, x, y, theta, k);
      fx += cfx;
      fy += cfy;
    }
    return (fx, fy);
  }
}
