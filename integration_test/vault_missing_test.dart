import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/core/brain_providers.dart';

/// 앱을 켰는데 지식 폴더가 없을 때 (11/11 K-33 나머지): 외장 디스크가 빠진 상태로 켜고 → 다시 연결 → [다시 확인].
///
/// BRAIN_VAULT=<사본> BRAIN_CONFIG=<임시 파일> flutter test integration_test/vault_missing_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
  }

  testWidgets('폴더가 빠져 있으면 묻는 화면, 다시 연결하고 [다시 확인]을 누르면 열린다', (tester) async {
    final root = Platform.environment['BRAIN_VAULT'] ?? '';
    expect(root, isNotEmpty, reason: '실제 지식 폴더 보호');
    expect(Platform.environment['BRAIN_CONFIG'] ?? '', isNotEmpty, reason: '실제 설정 보호');
    final vault = Vault(root);
    final index = SearchIndex.open(vault);
    index.sync();
    final count = index.notes().length;
    index.close();
    expect(count, greaterThan(0));

    // 디스크를 뺀 것처럼 폴더를 옆으로 옮긴다
    final away = '$root.away';
    Directory(root).renameSync(away);
    try {
      tester.view.physicalSize = const Size(2880, 1800);
      tester.view.devicePixelRatio = 2;
      await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
      await settle(tester, 2000);
      expect(find.text('지식 폴더를 찾지 못했습니다'), findsOneWidget);
      expect(Directory(root).existsSync(), isFalse, reason: '빈 폴더를 새로 만들면 안 된다');

      // 아직 연결 전 [다시 확인] → 그대로
      await tester.tap(find.text('다시 확인'));
      await settle(tester);
      expect(find.textContaining('아직 찾지 못했습니다'), findsOneWidget);

      // 다시 연결 → [다시 확인] → 앱이 열리고 노트가 그대로
      Directory(away).renameSync(root);
      await tester.tap(find.text('다시 확인'));
      await settle(tester, 3000);
      expect(find.text('지식 폴더를 찾지 못했습니다'), findsNothing);
      final container = ProviderScope.containerOf(tester.element(find.byType(SecondBrainApp)));
      expect(container.read(notesProvider), hasLength(count));
    } finally {
      if (Directory(away).existsSync() && !Directory(root).existsSync()) Directory(away).renameSync(root);
      tester.view.resetPhysicalSize();
    }
  });
}
