// 그래프 배치가 얼마나 꼬였는지 숫자와 그림으로 본다 (11/11 사용자 "그래프 꼬인 거").
//
// 실제 색인을 건드리지 않게 색인 파일 사본을 준다. 지식 폴더는 읽기만 한다(거절한 연결 목록).
//
//   cd packages/brain_core
//   dart run tool/graph_tangle.dart <지식 폴더> <색인 사본 index.db> <그림을 둘 폴더>
//
// 출력: 저장된 배치(사용자가 지금 보는 것)와 처음부터 다시 배치한 것의 지표, 각 배치의 SVG.
import 'dart:io';
import 'dart:math';

import 'package:brain_core/brain_core.dart';

void main(List<String> args) {
  if (args.length < 3) {
    stderr.writeln('사용법: dart run tool/graph_tangle.dart <지식 폴더> <색인 사본> <그림 폴더>');
    exit(64);
  }
  final vault = Vault(args[0]);
  final index = SearchIndex.open(vault, path: args[1]);
  final outDir = Directory(args[2])..createSync(recursive: true);

  final notes = [for (final d in index.notes()) if (!d.isMerged) d];
  final links = index.links(dismissed: DismissedLinks(vault).load());
  final nodes = [for (final d in notes) GraphNode(d.id, d.topic)];
  final ids = {for (final n in nodes) n.id};
  // 앱(graphLayoutProvider)과 같은 무게: 직접 연결 1, 추천 연결 0.25
  final edges = [
    for (final l in links)
      if (ids.contains(l.fromId) && ids.contains(l.toId))
        GraphEdge(l.fromId, l.toId, weight: l.isSuggested ? 0.25 : 1),
  ];
  final manual = [for (final e in edges) if (e.weight == 1) e];
  final groups = {for (final n in nodes) n.group};
  stdout.writeln(
    '노트 ${nodes.length}개 · 주제 ${groups.length}개 · 직접 연결 ${manual.length}개 · 추천 연결 ${edges.length - manual.length}개',
  );

  final stored = index.graphPositions();
  final missing = [for (final n in nodes) if (!stored.containsKey(n.id)) n.id];
  stdout.writeln('저장된 위치 ${stored.length}개 (노트 중 위치 없는 것 ${missing.length}개)');
  if (missing.isEmpty) {
    report('저장된 배치 (지금 화면)', nodes, edges, stored);
    writeSvg('${outDir.path}/stored.svg', nodes, edges, stored);
  }
  final legacy = forceLayout(nodes, edges, legacyGroupRing: true);
  report('처음부터 다시 배치 — 예전 방식(주제를 이름순 원에)', nodes, edges, legacy);
  writeSvg('${outDir.path}/fresh_legacy.svg', nodes, edges, legacy);
  final fresh = forceLayout(nodes, edges);
  report('처음부터 다시 배치 — 새 방식(주제 자리를 연결로 정함)', nodes, edges, fresh);
  writeSvg('${outDir.path}/fresh.svg', nodes, edges, fresh);
  final base = index.graphLayoutBase();
  stdout.writeln(
    '\n배치 기록: ${base == null ? '없음' : '규칙 ${base.version} · 노트 ${base.nodes} · 연결 ${base.links} · 겹침 ${base.crossings} · 섞임 ${base.stray}'}'
    ' → 지금 판단: ${decideLayout(nodes, edges, stored: stored, base: base).name}',
  );
  index.close();

  // 한 가지 자료에만 맞춘 것이 아닌지: 만든 그래프 여러 개로 예전 방식과 새 방식을 견준다.
  stdout.writeln('\n[만든 그래프로 견주기: 직접 연결끼리 겹침 (예전 → 새)]');
  for (final (n, g, seed) in [(120, 8, 1), (300, 12, 2), (300, 12, 3), (600, 20, 4), (1500, 30, 5)]) {
    final (sn, se) = synthetic(n, g, seed);
    final a = GraphMetrics.of(sn, se, forceLayout(sn, se, legacyGroupRing: true));
    final b = GraphMetrics.of(sn, se, forceLayout(sn, se));
    stdout.writeln(
      '  노트 $n·주제 $g·씨앗 $seed (직접 연결 ${se.where((e) => e.weight == 1).length}): '
      '겹침 ${a.manualCrossings} → ${b.manualCrossings}, 섞임 ${a.strayNodes} → ${b.strayNodes}, 겹친 노드 ${a.overlaps} → ${b.overlaps}',
    );
  }
}

/// 실제 지식 폴더와 비슷한 모양의 그래프: 주제 크기가 고르지 않고, 연결은 대부분 주제 안, 일부는 몇몇 주제 쌍 사이.
(List<GraphNode>, List<GraphEdge>) synthetic(int count, int groupCount, int seed) {
  final random = Random(seed);
  final groupOf = [for (var i = 0; i < count; i++) (pow(random.nextDouble(), 1.8) * groupCount).floor()];
  final nodes = [for (var i = 0; i < count; i++) GraphNode('s$i', 'g${groupOf[i].toString().padLeft(2, '0')}')];
  final byGroup = <int, List<int>>{};
  for (var i = 0; i < count; i++) {
    byGroup.putIfAbsent(groupOf[i], () => []).add(i);
  }
  final edges = <GraphEdge>[];
  // 주제 안: 노트의 60%가 같은 주제 노트 하나와 이어진다
  for (var i = 0; i < count; i++) {
    final peers = byGroup[groupOf[i]]!;
    if (peers.length > 1 && random.nextDouble() < 0.6) {
      final j = peers[random.nextInt(peers.length)];
      if (j != i) edges.add(GraphEdge('s$i', 's$j'));
    }
  }
  // 주제 사이: 주제 쌍 몇 개를 골라 그 사이에 연결을 몰아 준다
  final present = byGroup.keys.toList()..sort();
  for (var k = 0; k < present.length; k++) {
    final a = present[random.nextInt(present.length)], b = present[random.nextInt(present.length)];
    if (a == b) continue;
    final links = 2 + random.nextInt(4);
    for (var t = 0; t < links; t++) {
      final i = byGroup[a]![random.nextInt(byGroup[a]!.length)];
      final j = byGroup[b]![random.nextInt(byGroup[b]!.length)];
      edges.add(GraphEdge('s$i', 's$j'));
    }
  }
  // 추천 연결: 무작위 약한 연결
  for (var t = 0; t < count ~/ 3; t++) {
    final i = random.nextInt(count), j = random.nextInt(count);
    if (i != j) edges.add(GraphEdge('s$i', 's$j', weight: 0.25));
  }
  return (nodes, edges);
}

void report(String name, List<GraphNode> nodes, List<GraphEdge> edges, Map<String, Point<double>> pos) {
  final m = GraphMetrics.of(nodes, edges, pos);
  stdout.writeln('\n[$name]');
  stdout.writeln('  선 겹침(교차): 직접 연결끼리 ${m.manualCrossings}번 · 모든 연결 ${m.allCrossings}번');
  stdout.writeln(
    '  직접 연결 길이: 가운데 ${m.medianManual.toStringAsFixed(0)} · 가장 긴 10% ${m.p90Manual.toStringAsFixed(0)} (목표 길이 70)',
  );
  stdout.writeln('  다른 주제 무리에 더 가까운 노트: ${m.strayNodes}/${nodes.length}');
  stdout.writeln('  겹친 노드 쌍(거리 28 미만): ${m.overlaps}');
  stdout.writeln('  그림 크기: ${m.width.toStringAsFixed(0)} × ${m.height.toStringAsFixed(0)}');
}

class GraphMetrics {
  GraphMetrics({
    required this.manualCrossings,
    required this.allCrossings,
    required this.medianManual,
    required this.p90Manual,
    required this.strayNodes,
    required this.overlaps,
    required this.width,
    required this.height,
  });

  final int manualCrossings;
  final int allCrossings;
  final double medianManual;
  final double p90Manual;
  final int strayNodes;
  final int overlaps;
  final double width;
  final double height;

  static GraphMetrics of(List<GraphNode> nodes, List<GraphEdge> edges, Map<String, Point<double>> pos) {
    final manual = [for (final e in edges) if (e.weight == 1) e];
    final lengths = [for (final e in manual) pos[e.from]!.distanceTo(pos[e.to]!)]..sort();
    // 주제 무리의 가운데
    final sum = <String, (double, double, int)>{};
    for (final n in nodes) {
      final (x, y, c) = sum[n.group] ?? (0.0, 0.0, 0);
      sum[n.group] = (x + pos[n.id]!.x, y + pos[n.id]!.y, c + 1);
    }
    final center = {for (final e in sum.entries) e.key: Point(e.value.$1 / e.value.$3, e.value.$2 / e.value.$3)};
    var stray = 0;
    for (final n in nodes) {
      final own = pos[n.id]!.distanceTo(center[n.group]!);
      if (center.entries.any((e) => e.key != n.group && pos[n.id]!.distanceTo(e.value) < own)) stray++;
    }
    var overlaps = 0;
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        if (pos[nodes[i].id]!.distanceTo(pos[nodes[j].id]!) < 28) overlaps++;
      }
    }
    final xs = [for (final n in nodes) pos[n.id]!.x], ys = [for (final n in nodes) pos[n.id]!.y];
    return GraphMetrics(
      manualCrossings: crossings(manual, pos),
      allCrossings: crossings(edges, pos),
      medianManual: lengths.isEmpty ? 0 : lengths[lengths.length ~/ 2],
      p90Manual: lengths.isEmpty ? 0 : lengths[(lengths.length * 0.9).floor().clamp(0, lengths.length - 1)],
      strayNodes: stray,
      overlaps: overlaps,
      width: xs.reduce(max) - xs.reduce(min),
      height: ys.reduce(max) - ys.reduce(min),
    );
  }
}

/// 끝점을 함께 쓰지 않는 두 선이 서로 가로지르는 횟수.
int crossings(List<GraphEdge> edges, Map<String, Point<double>> pos) {
  double cross(Point<double> o, Point<double> a, Point<double> b) =>
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  var count = 0;
  for (var i = 0; i < edges.length; i++) {
    for (var j = i + 1; j < edges.length; j++) {
      final e = edges[i], f = edges[j];
      if (e.from == f.from || e.from == f.to || e.to == f.from || e.to == f.to) continue;
      final a = pos[e.from]!, b = pos[e.to]!, c = pos[f.from]!, d = pos[f.to]!;
      if (cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0) count++;
    }
  }
  return count;
}

void writeSvg(String path, List<GraphNode> nodes, List<GraphEdge> edges, Map<String, Point<double>> pos) {
  const palette = [
    '#8b7cf6', '#f59e0b', '#10b981', '#ef4444', '#3b82f6', '#ec4899', '#14b8a6', '#eab308', '#a855f7', '#64748b',
  ];
  final groups = {for (final n in nodes) n.group}.toList()..sort();
  final xs = [for (final n in nodes) pos[n.id]!.x], ys = [for (final n in nodes) pos[n.id]!.y];
  final minX = xs.reduce(min) - 60, minY = ys.reduce(min) - 60;
  final w = xs.reduce(max) - minX + 60, h = ys.reduce(max) - minY + 60;
  final b = StringBuffer()
    ..writeln('<svg xmlns="http://www.w3.org/2000/svg" viewBox="$minX $minY $w $h" width="1400" height="${(1400 * h / w).round()}">')
    ..writeln('<rect x="$minX" y="$minY" width="$w" height="$h" fill="#14141c"/>');
  for (final e in edges) {
    final a = pos[e.from]!, c = pos[e.to]!;
    final isManual = e.weight == 1;
    b.writeln(
      '<line x1="${a.x}" y1="${a.y}" x2="${c.x}" y2="${c.y}" stroke="${isManual ? '#c8c8e0' : '#55556a'}" '
      'stroke-width="${isManual ? 1.4 : 0.6}" opacity="${isManual ? 0.8 : 0.5}"/>',
    );
  }
  for (final n in nodes) {
    final q = pos[n.id]!;
    b.writeln('<circle cx="${q.x}" cy="${q.y}" r="7" fill="${palette[groups.indexOf(n.group) % palette.length]}"/>');
  }
  for (final (i, g) in groups.indexed) {
    final members = [for (final n in nodes) if (n.group == g) pos[n.id]!];
    final cx = members.map((q) => q.x).reduce((a, c) => a + c) / members.length;
    final cy = members.map((q) => q.y).reduce((a, c) => a + c) / members.length;
    b.writeln(
      '<text x="$cx" y="${cy - 14}" fill="${palette[i % palette.length]}" font-size="20" text-anchor="middle" '
      'font-family="sans-serif">${g.replaceAll('&', '&amp;').replaceAll('<', '&lt;')} (${members.length})</text>',
    );
  }
  b.writeln('</svg>');
  File(path).writeAsStringSync(b.toString());
}
