import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:brain_core/brain_core.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/core/brain_providers.dart';

/// 꼬인 채 저장된 그래프 배치를 앱이 스스로 다시 배치하는지, [다시 배치] 버튼이 도는지 본다
/// (설계서 5.5 "꼬임 막기" v1.3.28, 11/11 사용자 "그래프 꼬인 거").
///
/// 지식 폴더 사본과, 그 사본의 색인 자리에 "꼬인 위치가 저장된 색인" 사본을 두고 돌린다.
/// 꼬인 색인이 없으면 시험이 섞은 순서의 원 배치를 저장해 만든다(`tool/run_integration.sh`로 한 명령 실행).
/// 색인 자리는 ~/Library/Caches/com.konga22.secondbrain/<사본 경로 sha1 앞 12자>/index.db 다.
///
/// BRAIN_VAULT=<지식 폴더 사본> BRAIN_CONFIG=<임시 파일> flutter test \
///   integration_test/graph_untangle_test.dart -d macos [--dart-define=SHOT_DIR=<캡처 폴더>]
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const shotDir = String.fromEnvironment('SHOT_DIR');

  Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
    for (var i = 0; i < ms ~/ 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (shotDir.isEmpty) return;
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final image = await layer.toImage(Offset.zero & (view.size * 2), pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$shotDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  testWidgets('꼬인 배치를 스스로 다시 배치하고, [다시 배치]가 돈다', (tester) async {
    final env = Platform.environment;
    expect(env['BRAIN_VAULT'] ?? '', isNotEmpty, reason: '실제 지식 폴더 보호: BRAIN_VAULT에 사본을 주세요');
    expect(env['BRAIN_CONFIG'] ?? '', isNotEmpty, reason: '실제 설정 보호: BRAIN_CONFIG에 임시 파일을 주세요');

    // 앱을 띄우기 전: 저장된 배치가 실제로 꼬여 있고 기록이 없는 상태인지 (빈 통과가 아니게).
    final vault = Vault.resolve();
    final before = SearchIndex.open(vault);
    // 준비된 꼬인 색인이 없으면(새 사본, tool/run_integration.sh) 여기서 만든다: 노트를 섞은 순서로 원 위에 놓으면
    // 연결선이 원 안을 가로질러 꼬인다. 배치 기록(base)은 남기지 않는다 = 예전 배치 (K-38, 11/12).
    if (before.graphPositions().isEmpty || before.graphLayoutBase() != null) {
      before.sync();
      final ids = [for (final d in before.notes()) if (!d.isMerged) d.id]..shuffle(Random(7));
      before.clearGraphLayout();
      before.saveGraphPositions({
        for (var i = 0; i < ids.length; i++)
          ids[i]: Point(600 * cos(2 * pi * i / ids.length), 600 * sin(2 * pi * i / ids.length)),
      });
    }
    final storedBefore = before.graphPositions();
    final baseBefore = before.graphLayoutBase();
    final notesBefore = [for (final d in before.notes()) if (!d.isMerged) GraphNode(d.id, d.topicPath)];
    final edgesBefore = [
      for (final l in before.links(dismissed: DismissedLinks(vault).load()))
        GraphEdge(l.fromId, l.toId, weight: l.isSuggested ? 0.25 : 1),
    ];
    final statsBefore = layoutStats(notesBefore, edgesBefore, storedBefore);
    before.close();
    expect(storedBefore, isNotEmpty, reason: '색인 사본에 저장된 위치가 있어야 한다');
    expect(baseBefore, isNull, reason: '예전 배치(기록 없음)에서 시작해야 한다');
    expect(statsBefore.crossings, greaterThan(10), reason: '저장된 배치가 꼬여 있어야 견줄 수 있다');

    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    await settle(tester, 5000);
    final container = ProviderScope.containerOf(tester.element(find.byType(SecondBrainApp)));

    Future<LayoutStats> statsNow() async {
      final positions = await container.read(graphLayoutProvider.future);
      final nodes = [for (final d in container.read(notesProvider)) if (!d.isMerged) GraphNode(d.id, d.topicPath)];
      final edges = [
        for (final l in container.read(linksProvider)) GraphEdge(l.fromId, l.toId, weight: l.isSuggested ? 0.25 : 1),
      ];
      expect(positions.length, nodes.length);
      return layoutStats(nodes, edges, positions);
    }

    // 1) 앱을 켜기만 해도 다시 배치돼 있다.
    final after = await statsNow();
    await shot(tester, 'graph_after_auto');
    // ignore: avoid_print
    print('[그래프] 직접 연결 겹침 ${statsBefore.crossings} → ${after.crossings}, 다른 주제에 섞인 노트 ${statsBefore.stray} → ${after.stray}');
    expect(after.crossings, lessThan(statsBefore.crossings ~/ 3));
    expect(after.stray, lessThan(statsBefore.stray));
    final index = container.read(searchIndexProvider);
    expect(index.graphLayoutBase(), isNotNull, reason: '전체 배치를 했으면 기록이 남아야 한다');
    expect(index.graphLayoutBase()!.version, layoutVersion);

    // 2) 바뀐 것이 없으면 다시 배치하지 않는다 (같은 위치).
    final first = await container.read(graphLayoutProvider.future);
    container.invalidate(graphLayoutProvider);
    await settle(tester, 1000);
    final second = await container.read(graphLayoutProvider.future);
    expect(second[second.keys.first], first[first.keys.first]);

    // 3) [다시 배치] 버튼: 위치와 기록을 지우고 다시 만든다. 누른 뒤에도 그래프가 그려져 있어야 한다.
    // 빈 통과가 아니게(L-0006): 기록에 표식(겹침 9999)을 남겨 두고, 버튼이 실제로 기록을 지우고 다시 만들었는지 본다.
    final marked = index.graphLayoutBase()!;
    index.saveGraphPositions(
      index.graphPositions(),
      base: LayoutBase(
        version: marked.version,
        nodes: marked.nodes,
        links: marked.links,
        groups: marked.groups,
        crossings: 9999,
        stray: marked.stray,
      ),
    );
    final button = find.text('다시 배치');
    expect(button, findsOneWidget);
    await tester.tap(button);
    await settle(tester, 3000);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('그래프를 그리지 못했습니다'), findsNothing);
    final again = await statsNow();
    expect(again.crossings, lessThan(statsBefore.crossings ~/ 3));
    expect(index.graphLayoutBase(), isNotNull);
    expect(index.graphLayoutBase()!.crossings, isNot(9999), reason: '[다시 배치]를 눌렀는데 기록이 그대로다 (탭이 안 먹었거나 버튼이 아무 일도 안 함)');
    expect(index.graphPositions().length, first.length);
    await shot(tester, 'graph_after_button');
  });
}
