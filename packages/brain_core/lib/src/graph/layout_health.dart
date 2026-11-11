import 'dart:math';

import 'force_layout.dart';

/// 배치 규칙 번호. 전체 배치의 모양이 바뀌면 올린다 — 저장된 배치를 한 번 다시 만든다 (설계서 5.5 v1.3.28).
const layoutVersion = 2;

/// 전체 배치를 한 때의 기록. 그 뒤 배치가 얼마나 나빠졌는지 견주는 기준이다.
class LayoutBase {
  const LayoutBase({
    required this.version,
    required this.nodes,
    required this.links,
    required this.groups,
    required this.crossings,
    required this.stray,
  });

  final int version;

  /// 노트 수, 직접 연결 수, 주제 구성 서명 ([groupSignature]).
  final int nodes;
  final int links;
  final int groups;

  /// 그때의 선 겹침 수와 "다른 주제 무리에 더 가까운 노트" 수.
  final int crossings;
  final int stray;

  static LayoutBase of(List<GraphNode> nodes, List<GraphEdge> edges, Map<String, Point<double>> positions) {
    final stats = layoutStats(nodes, edges, positions);
    return LayoutBase(
      version: layoutVersion,
      nodes: nodes.length,
      links: _manualCount(edges),
      groups: groupSignature(nodes),
      crossings: stats.crossings,
      stray: stats.stray,
    );
  }
}

class LayoutStats {
  const LayoutStats({required this.crossings, required this.stray});

  /// 직접 연결끼리 가로지르는 횟수 (연결이 많으면 [sample]개만 골라 센다).
  final int crossings;

  /// 자기 주제 무리의 가운데보다 다른 주제 무리의 가운데에 더 가까운 노트 수.
  final int stray;
}

enum LayoutAction {
  /// 저장된 위치 그대로.
  keep,

  /// 기존 노드는 두고 새 노드만 자리를 잡는다.
  placeNew,

  /// 처음부터 다시 배치한다.
  full,
}

class LayoutResult {
  const LayoutResult(this.action, this.positions, this.base);

  final LayoutAction action;
  final Map<String, Point<double>> positions;

  /// 전체 배치를 했을 때만 있다. 색인에 기록으로 남긴다.
  final LayoutBase? base;
}

int _manualCount(List<GraphEdge> edges) => edges.where((e) => e.weight >= 1).length;

/// 어느 노트가 어느 주제에 있는지의 서명. 노트가 다른 폴더로 옮겨지거나 더해지거나 빠지면 바뀐다.
/// (String.hashCode는 실행 환경에 따라 다를 수 있어 직접 계산한다.)
int groupSignature(List<GraphNode> nodes) {
  var total = 0;
  for (final n in nodes) {
    var h = 0x811c9dc5;
    for (final unit in n.id.codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0x7fffffff;
    }
    h = ((h ^ 0x1f) * 0x01000193) & 0x7fffffff;
    for (final unit in n.group.codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0x7fffffff;
    }
    // 곱하기만으로는 아랫자리가 윗자리에 섞이지 않아, 주제 이름 끝 글자만 서로 바꾼 경우 합이 같게 나왔다
    // (시험 "노트를 다른 폴더로 많이 옮기면"). 윗자리를 아랫자리로 접어 한 번 더 섞는다.
    h ^= h >> 15;
    h = (h * 0x2c1b3c6d) & 0x7fffffff;
    h ^= h >> 12;
    h = (h * 0x297a2d39) & 0x7fffffff;
    h ^= h >> 15;
    total = (total + h) & 0x7fffffff;
  }
  return total;
}

/// 배치가 얼마나 꼬였는지. 위치가 없는 노드와 그 노드의 연결은 빼고 잰다.
LayoutStats layoutStats(
  List<GraphNode> nodes,
  List<GraphEdge> edges,
  Map<String, Point<double>> positions, {
  int sample = 400,
}) {
  final sum = <String, (double, double, int)>{};
  for (final n in nodes) {
    final p = positions[n.id];
    if (p == null) continue;
    final (x, y, c) = sum[n.group] ?? (0.0, 0.0, 0);
    sum[n.group] = (x + p.x, y + p.y, c + 1);
  }
  final centers = [for (final e in sum.entries) (e.key, e.value.$1 / e.value.$3, e.value.$2 / e.value.$3)];
  var stray = 0;
  for (final n in nodes) {
    final p = positions[n.id];
    if (p == null) continue;
    var own = double.infinity, other = double.infinity;
    for (final (group, cx, cy) in centers) {
      final d = (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy);
      if (group == n.group) {
        own = d;
      } else if (d < other) {
        other = d;
      }
    }
    if (other < own) stray++;
  }

  var manual = [
    for (final e in edges)
      if (e.weight >= 1 && e.from != e.to && positions.containsKey(e.from) && positions.containsKey(e.to)) e,
  ];
  if (manual.length > sample) {
    // 고르게 건너뛰며 고른다 (난수 없이, 같은 입력이면 같은 결과).
    final stride = manual.length / sample;
    manual = [for (var i = 0; i < sample; i++) manual[(i * stride).floor()]];
  }
  double cross(Point<double> o, Point<double> a, Point<double> b) =>
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  var crossings = 0;
  for (var i = 0; i < manual.length; i++) {
    final e = manual[i];
    final a = positions[e.from]!, b = positions[e.to]!;
    for (var j = i + 1; j < manual.length; j++) {
      final f = manual[j];
      if (e.from == f.from || e.from == f.to || e.to == f.from || e.to == f.to) continue;
      final c = positions[f.from]!, d = positions[f.to]!;
      if (cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0) crossings++;
    }
  }
  return LayoutStats(crossings: crossings, stray: stray);
}

/// 기록([base])보다 배치가 기준 넘게 나빠졌는가 (설계서 5.5 "다시 배치하는 조건" 3번).
bool _isWorse(LayoutStats now, LayoutBase base, int nodeCount) =>
    now.crossings > base.crossings * 2 + 5 || now.stray > base.stray + max(3, (nodeCount * 0.1).round());

/// 저장된 배치([stored])를 그대로 쓸지, 새 노드만 자리를 잡을지, 처음부터 다시 배치할지 정한다.
///
/// 새 노드만 끼워 넣기를 되풀이하면 배치가 꼬인다 (11/11 실제 지식 폴더: 직접 연결 47개가 43번 겹침,
/// 다시 배치하면 3번). 노트 수·연결 수·주제 구성이 기록과 같으면 아무것도 재지 않고 그대로 쓴다.
LayoutAction decideLayout(
  List<GraphNode> nodes,
  List<GraphEdge> edges, {
  required Map<String, Point<double>> stored,
  required LayoutBase? base,
}) {
  if (nodes.isEmpty) return LayoutAction.keep;
  if (base == null || base.version < layoutVersion) return LayoutAction.full;
  final isAllPlaced = nodes.every((n) => stored.containsKey(n.id));
  if (isAllPlaced &&
      nodes.length == base.nodes &&
      _manualCount(edges) == base.links &&
      groupSignature(nodes) == base.groups) {
    return LayoutAction.keep;
  }
  final placed = nodes.where((n) => stored.containsKey(n.id)).length;
  if (placed < 2) return LayoutAction.full;
  if (nodes.length - base.nodes > max(10, (base.nodes * 0.2).round())) return LayoutAction.full;
  if (_isWorse(layoutStats(nodes, edges, stored), base, nodes.length)) return LayoutAction.full;
  return isAllPlaced ? LayoutAction.keep : LayoutAction.placeNew;
}

/// [decideLayout]대로 배치한다. 새 노드만 자리를 잡았는데 결과가 기준을 넘으면 전체 배치로 바꾼다.
/// 노드가 많으면 오래 걸리므로(1만 개 약 13초) 앱은 백그라운드에서 부른다.
LayoutResult layoutGraph(
  List<GraphNode> nodes,
  List<GraphEdge> edges, {
  required Map<String, Point<double>> stored,
  required LayoutBase? base,
}) {
  var action = decideLayout(nodes, edges, stored: stored, base: base);
  if (action == LayoutAction.keep) {
    return LayoutResult(action, {for (final n in nodes) n.id: stored[n.id]!}, null);
  }
  if (action == LayoutAction.placeNew) {
    final positions = forceLayout(nodes, edges, initial: stored);
    if (!_isWorse(layoutStats(nodes, edges, positions), base!, nodes.length)) {
      return LayoutResult(action, positions, null);
    }
    action = LayoutAction.full;
  }
  final positions = forceLayout(nodes, edges);
  return LayoutResult(action, positions, LayoutBase.of(nodes, edges, positions));
}
