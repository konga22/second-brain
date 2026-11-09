import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/router/app_page.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/core/app_config_provider.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:secondbrain/features/home/structure_list_view.dart';

/// 모든 화면을 돌며 예외 없이 그려지는지 본다. 노트를 하나 골라 오른쪽 패널, ⌘K 명령 창도 연다.
/// 실제 지식 폴더를 쓰지 않도록 BRAIN_VAULT에 사본을 주고 돌린다.
///
/// BRAIN_VAULT=<사본> flutter test integration_test/screens_test.dart -d macos \
///   [--dart-define=SHOT_DIR=<캡처 폴더>]
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

  testWidgets('모든 화면이 예외 없이 그려진다', (tester) async {
    final vault = Platform.environment['BRAIN_VAULT'] ?? '';
    expect(vault, isNotEmpty, reason: '실제 지식 폴더 보호: BRAIN_VAULT에 사본을 주세요');
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    await settle(tester, 3000);
    final container = ProviderScope.containerOf(tester.element(find.byType(SecondBrainApp)));
    final router = GoRouter.of(tester.element(find.byType(Navigator).first));
    // --dart-define=ZOOM=1.6 이면 그 화면 배율로 모든 화면을 돈다 (넘침 찾기). 끝나면 되돌린다.
    final zoom = double.tryParse(const String.fromEnvironment('ZOOM')) ?? 0;
    final originalScale = container.read(appConfigProvider).uiScale;
    if (zoom > 0) {
      // 파일에는 저장하지 않는다 (사용자 설정을 건드리지 않게).
      container.read(appConfigProvider.notifier).update((c) => c.copyWith(uiScale: zoom), save: false);
      await settle(tester);
    }

    await shot(tester, '01_home_graph');
    for (final (i, label) in ['목록', '타임라인', '정리 보드'].indexed) {
      await tester.tap(find.text(label).first);
      await settle(tester);
      await shot(tester, '0${i + 2}_home_$label');
    }
    final notes = container.read(notesProvider);
    if (notes.isNotEmpty) {
      container.read(selectedNoteProvider.notifier).select(notes.first.id);
      await settle(tester);
      await shot(tester, '05_note_panel');
      // 목록에서 고른 노트의 연결 호, 주제를 눌렀을 때 주제 사이 호
      await tester.tap(find.text('목록').first);
      await settle(tester);
      await shot(tester, '06_list_selected');
      final topicText = find.descendant(
        of: find.byType(StructureListView),
        matching: find.text(notes.first.topic),
      );
      if (topicText.evaluate().isNotEmpty) {
        await tester.tap(topicText.first);
        await settle(tester);
        await shot(tester, '07_list_topic');
      }
    }
    for (final page in AppPage.values.where((p) => p != AppPage.home)) {
      router.go(page.path);
      await settle(tester);
      await shot(tester, '1${page.index}_${page.name}');
      // 배운 것: 적용 탭의 규칙 카드(만듦·마지막 적용 날짜)도 찍는다 (설계서 3.0 날짜 표시)
      // 설명 문장에도 '적용'이 있어 탭 이름('적용 12')만 정확히 고른다 (11/09 빈 캡처를 고침)
      final activeTab = find.byWidgetPredicate((w) => w is Text && RegExp(r'^적용 \d+$').hasMatch(w.data ?? ''));
      if (page == AppPage.lessons && activeTab.evaluate().isNotEmpty) {
        await tester.tap(activeTab.first);
        await settle(tester);
        await shot(tester, '1${page.index}b_lessons_active');
      }
    }
    router.go(AppPage.home.path);
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await settle(tester);
    await shot(tester, '20_command_palette');
    expect(find.text('노트 찾기, 화면 이동, 새 노트…'), findsOneWidget);
    container.read(appConfigProvider.notifier).update((c) => c.copyWith(uiScale: originalScale), save: false);
    tester.view.resetPhysicalSize();
  });
}
