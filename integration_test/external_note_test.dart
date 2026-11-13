import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/core/brain_providers.dart';

/// 앱 밖에서 생긴 노트가 새로고침 없이 보이는가 (설계서 v1.3.24, 11/09 사용자 제보).
/// Claude Code가 `brain add`로 저장하면 CLI가 같은 색인을 먼저 맞춰 둔다. 그래서 앱의 색인 확인이
/// "바뀐 것 0개"가 되어 화면을 다시 그리지 않았다. 여기서는 CLI처럼 따로 연 색인으로 노트를 더한다.
///
/// BRAIN_VAULT=<지식 폴더 사본> BRAIN_CONFIG=<시험용 config> flutter test integration_test/external_note_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }
  }

  testWidgets('CLI처럼 바깥에서 더한 노트가 3초 안에 앱 목록에 뜬다', (tester) async {
    final root = Platform.environment['BRAIN_VAULT'] ?? '';
    expect(root, isNotEmpty, reason: '실제 지식 폴더 보호: BRAIN_VAULT에 사본을 주세요');
    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    await settle(tester, 3000);
    final container = ProviderScope.containerOf(tester.element(find.byType(SecondBrainApp)));
    final before = container.read(notesProvider).length;

    // CLI(brain add)와 같은 방식: 따로 연 색인으로 저장 → 색인은 이미 최신
    final vault = Vault(root);
    final index = SearchIndex.open(vault);
    final title = '바깥 노트 시험 ${DateTime.now().millisecondsSinceEpoch}';
    final (id, _) = NoteStore(vault, index).add(title: title, summary: '앱 밖에서 더한 노트', body: '본문', topic: '개발 지식/시험', draft: true);
    index.close();

    var seenAfterMs = -1;
    for (var ms = 0; ms <= 3000; ms += 200) {
      await settle(tester, 200);
      if (container.read(notesProvider).any((d) => d.id == id)) {
        seenAfterMs = ms + 200;
        break;
      }
    }
    // ignore: avoid_print
    print('[바깥 노트] $id 앱에 보인 시각: ${seenAfterMs < 0 ? '3초 안에 안 보임' : '$seenAfterMs ms'} (전 $before개)');
    expect(seenAfterMs, greaterThan(0));
  });
}
