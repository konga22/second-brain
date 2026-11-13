import 'dart:io';
import 'dart:math';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 그래프 꼬임 막기 (설계서 5.5 v1.3.28). 11/11 실제 지식 폴더에서 직접 연결 47개가 43번 겹쳤다:
/// 새 노드만 끼워 넣기를 되풀이했고, 주제를 이름순으로 원 위에 놓았기 때문이다.
void main() {
  /// 주제 [groups]개, 주제마다 [size]개. 주제 안은 사슬로 잇고 [between]의 주제 쌍 사이에 연결 4개씩.
  (List<GraphNode>, List<GraphEdge>) clusters(int groups, int size, List<(int, int)> between) {
    final nodes = [
      for (var g = 0; g < groups; g++)
        for (var i = 0; i < size; i++) GraphNode('g${g}_$i', 'topic$g'),
    ];
    final edges = [
      for (var g = 0; g < groups; g++)
        for (var i = 0; i + 1 < size; i++) GraphEdge('g${g}_$i', 'g${g}_${i + 1}'),
      for (final (a, b) in between)
        for (var i = 0; i < 4; i++) GraphEdge('g${a}_$i', 'g${b}_$i'),
    ];
    return (nodes, edges);
  }

  test('주제 자리: 연결이 많은 주제끼리 가까이 놓여 선 겹침이 준다', () {
    // 이름순 원에서는 0–3, 1–4, 2–5가 모두 맞은편이라 주제 사이 선이 가운데서 엇갈린다.
    final (nodes, edges) = clusters(6, 8, [(0, 3), (1, 4), (2, 5)]);
    final before = layoutStats(nodes, edges, forceLayout(nodes, edges, legacyGroupRing: true));
    final after = layoutStats(nodes, edges, forceLayout(nodes, edges));
    expect(before.crossings, greaterThan(10), reason: '예전 방식에서 실제로 겹쳐야 견줄 수 있다');
    expect(after.crossings, lessThan(before.crossings ~/ 3), reason: '예전 ${before.crossings} → 새 ${after.crossings}');
    expect(after.stray, lessThanOrEqualTo(before.stray));
  });

  test('같은 입력이면 같은 배치이고, 노드가 겹치지 않는다', () {
    final (nodes, edges) = clusters(5, 40, [(0, 1), (2, 3)]);
    final first = forceLayout(nodes, edges);
    final second = forceLayout(nodes, edges);
    expect(first['g3_7'], second['g3_7']);
    var closest = double.infinity;
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        closest = min(closest, first[nodes[i].id]!.distanceTo(first[nodes[j].id]!));
      }
    }
    expect(closest, greaterThan(28), reason: '가장 가까운 두 노드 사이 $closest');
  });

  group('다시 배치하는 조건', () {
    late List<GraphNode> nodes;
    late List<GraphEdge> edges;
    late LayoutResult first;

    setUp(() {
      (nodes, edges) = clusters(5, 20, [(0, 1), (1, 2)]);
      first = layoutGraph(nodes, edges, stored: const {}, base: null);
    });

    test('기록이 없으면 전체 배치하고 기록을 남긴다', () {
      expect(first.action, LayoutAction.full);
      expect(first.base, isNotNull);
      expect(first.base!.nodes, 100);
      expect(first.positions, hasLength(100));
    });

    test('바뀐 것이 없으면 그대로 쓴다 (전체 배치를 되풀이하지 않는다)', () {
      expect(decideLayout(nodes, edges, stored: first.positions, base: first.base), LayoutAction.keep);
      final again = layoutGraph(nodes, edges, stored: first.positions, base: first.base);
      expect(again.action, LayoutAction.keep);
      expect(again.positions['g2_5'], first.positions['g2_5']);
    });

    test('노트 몇 개가 늘면 새 노드만 자리를 잡고 기존 노드는 그대로다', () {
      final more = [...nodes, const GraphNode('new1', 'topic2'), const GraphNode('new2', 'topic4')];
      final moreEdges = [...edges, const GraphEdge('new1', 'g2_3'), const GraphEdge('new2', 'g4_0')];
      final result = layoutGraph(more, moreEdges, stored: first.positions, base: first.base);
      expect(result.action, LayoutAction.placeNew);
      expect(result.base, isNull, reason: '기록은 전체 배치 때만 바뀐다 — 그래야 나빠진 정도가 쌓여 보인다');
      expect(result.positions['g0_0'], first.positions['g0_0']);
      expect(result.positions['new1']!.distanceTo(first.positions['g2_3']!), lessThan(200));
    });

    test('노트가 20% 넘게 늘면 전체 배치', () {
      final more = [...nodes, for (var i = 0; i < 25; i++) GraphNode('bulk$i', 'topic${i % 5}')];
      expect(decideLayout(more, edges, stored: first.positions, base: first.base), LayoutAction.full);
    });

    test('연결이 바뀌어 선이 많이 겹치게 되면 전체 배치', () {
      // 위치는 그대로인데 멀리 떨어진 노드끼리 연결이 생긴 경우 (실제로 꼬인 원인).
      final random = Random(7);
      final tangled = [
        ...edges,
        for (var i = 0; i < 40; i++) GraphEdge('g${random.nextInt(5)}_${random.nextInt(20)}', 'g${random.nextInt(5)}_${random.nextInt(20)}'),
      ];
      final now = layoutStats(nodes, tangled, first.positions);
      expect(now.crossings, greaterThan(first.base!.crossings * 2 + 5), reason: '시험 자료가 실제로 꼬여야 한다');
      expect(decideLayout(nodes, tangled, stored: first.positions, base: first.base), LayoutAction.full);
      final fixed = layoutGraph(nodes, tangled, stored: first.positions, base: first.base);
      expect(fixed.action, LayoutAction.full);
      expect(layoutStats(nodes, tangled, fixed.positions).crossings, lessThan(now.crossings));
    });

    test('노트를 다른 폴더로 많이 옮기면 전체 배치', () {
      final moved = [
        for (final n in nodes) n.id.endsWith('_0') || n.id.endsWith('_1') || n.id.endsWith('_2') || n.id.endsWith('_3')
            ? GraphNode(n.id, 'topic${(int.parse(n.group.substring(5)) + 2) % 5}')
            : n,
      ];
      final now = layoutStats(moved, edges, first.positions);
      expect(
        decideLayout(moved, edges, stored: first.positions, base: first.base),
        LayoutAction.full,
        reason: '섞인 노트: 기록 ${first.base!.stray} → 지금 ${now.stray} (노트 ${moved.length})',
      );
    });

    test('배치 규칙 번호가 낮은 기록이면 전체 배치', () {
      final old = LayoutBase(
        version: layoutVersion - 1,
        nodes: first.base!.nodes,
        links: first.base!.links,
        groups: first.base!.groups,
        crossings: first.base!.crossings,
        stray: first.base!.stray,
      );
      expect(decideLayout(nodes, edges, stored: first.positions, base: old), LayoutAction.full);
    });

    test('노트를 하나씩 60번 더해도 겹침이 기준 안에 머문다', () {
      final random = Random(3);
      var allNodes = nodes, allEdges = edges;
      var stored = first.positions;
      var base = first.base!;
      var fulls = 0;
      for (var i = 0; i < 60; i++) {
        final target = allNodes[random.nextInt(allNodes.length)];
        final other = allNodes[random.nextInt(allNodes.length)];
        allNodes = [...allNodes, GraphNode('add$i', 'topic${random.nextInt(5)}')];
        allEdges = [...allEdges, GraphEdge('add$i', target.id), GraphEdge('add$i', other.id)];
        final result = layoutGraph(allNodes, allEdges, stored: stored, base: base);
        stored = result.positions;
        if (result.base != null) {
          base = result.base!;
          fulls++;
        }
      }
      final end = layoutStats(allNodes, allEdges, stored);
      expect(end.crossings, lessThanOrEqualTo(base.crossings * 2 + 5));
      expect(fulls, greaterThan(0), reason: '60개가 늘었으니 적어도 한 번은 전체 배치를 다시 했어야 한다');
      // 예전 방식(새 노드만 끼워 넣기만 되풀이)과 견준다.
      expect(fulls, lessThan(30), reason: '거의 매번 전체 배치를 하면 화면이 계속 흔들린다 (전체 배치 $fulls번)');
    });
  });

  test('배치 기록을 색인에 남기고 읽는다, [다시 배치]는 둘 다 지운다', () {
    final temp = Directory.systemTemp.createTempSync('layout_');
    final index = SearchIndex.open(Vault(p.join(temp.path, 'SecondBrain')), path: p.join(temp.path, 'index.db'));
    addTearDown(() {
      index.close();
      temp.deleteSync(recursive: true);
    });
    expect(index.graphLayoutBase(), isNull);
    final (nodes, edges) = clusters(3, 5, [(0, 1)]);
    final result = layoutGraph(nodes, edges, stored: index.graphPositions(), base: index.graphLayoutBase());
    index.saveGraphPositions(result.positions, base: result.base);
    final saved = index.graphLayoutBase()!;
    expect(saved.version, layoutVersion);
    expect(saved.nodes, 15);
    expect(saved.groups, groupSignature(nodes));
    expect(decideLayout(nodes, edges, stored: index.graphPositions(), base: saved), LayoutAction.keep);
    index.clearGraphLayout();
    expect(index.graphPositions(), isEmpty);
    expect(index.graphLayoutBase(), isNull);
  });
}
