import 'dart:io';
import 'dart:ui' as ui;

import 'package:brain_core/brain_core.dart';
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
import 'package:secondbrain/features/notes/note_panel.dart';

/// 모든 화면을 돌며 예외 없이 그려지는지 본다. 노트를 하나 골라 오른쪽 패널, ⌘K 명령 창도 연다.
/// 실제 지식 폴더를 쓰지 않도록 BRAIN_VAULT에 사본을 주고 돌린다.
///
/// BRAIN_VAULT=<사본> BRAIN_CONFIG=<임시 파일> flutter test integration_test/screens_test.dart -d macos \
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
    expect(Platform.environment['BRAIN_CONFIG'] ?? '', isNotEmpty, reason: '실제 설정 보호: BRAIN_CONFIG=<임시 파일>');
    // 어디서 멈추는지 기록에 남긴다 (11/12 한 명령 실행에서 26분 멈춤, K-38).
    void step(String name) => debugPrint('[단계] $name');
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

    step('홈 그래프');
    await shot(tester, '01_home_graph');
    for (final (i, label) in ['목록', '타임라인', '정리 보드'].indexed) {
      step('홈 $label');
      await tester.tap(find.text(label).first);
      await settle(tester);
      await shot(tester, '0${i + 2}_home_$label');
    }
    final notes = container.read(notesProvider);
    if (notes.isNotEmpty) {
      step('노트 패널');
      container.read(selectedNoteProvider.notifier).select(notes.first.id);
      await settle(tester);
      await shot(tester, '05_note_panel');
      // 출처 칸 (설계서 v1.3.26): 세션에서 나온 노트를 열고 패널을 내려 실제로 그려졌는지,
      // [원본 열기]를 누르면 세션 축약본으로 가는지 본다. 그런 노트가 없는 지식 폴더면 건너뛴다.
      final vaultRoot = container.read(vaultProvider).root;
      final fromSession = notes.where((doc) {
        final file = File('$vaultRoot/${doc.path}');
        if (!file.existsSync()) return false;
        final note = Note.parse(file.readAsStringSync(), fallbackId: doc.id, fallbackTitle: doc.title);
        return note.sources.any((s) => s.startsWith('raw/sessions/') && File('$vaultRoot/$s').existsSync());
      }).firstOrNull;
      step('출처 칸 ${fromSession?.id}');
      if (fromSession != null) {
        container.read(selectedNoteProvider.notifier).select(fromSession.id);
        await settle(tester);
        final originTitle = find.text('출처 — 이 지식이 나온 곳');
        await tester.scrollUntilVisible(
          originTitle,
          300,
          scrollable: find.descendant(of: find.byType(NotePanel), matching: find.byType(Scrollable)).first,
          maxScrolls: 60,
        );
        await tester.scrollUntilVisible(
          find.text('원본 열기').first,
          200,
          scrollable: find.descendant(of: find.byType(NotePanel), matching: find.byType(Scrollable)).first,
          maxScrolls: 20,
        );
        await settle(tester, 400);
        expect(originTitle, findsOneWidget);
        expect(find.textContaining('시작 · 세션'), findsWidgets);
        await shot(tester, '05b_note_origin');
        await tester.tap(find.text('원본 열기').first);
        await settle(tester);
        expect(container.read(selectedNoteProvider), startsWith('r_'), reason: '[원본 열기]가 세션 축약본을 열어야 한다');
        await shot(tester, '05c_origin_raw');
        container.read(selectedNoteProvider.notifier).select(notes.first.id);
        await settle(tester);
      }
      step('목록 선택');
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
      step('화면 ${page.name}');
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
    step('⌘K');
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
