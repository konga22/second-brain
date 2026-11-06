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
import 'package:secondbrain/core/brain_providers.dart';

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
    }
    for (final page in AppPage.values.where((p) => p != AppPage.home)) {
      router.go(page.path);
      await settle(tester);
      await shot(tester, '1${page.index}_${page.name}');
    }
    router.go(AppPage.home.path);
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await settle(tester);
    await shot(tester, '20_command_palette');
    expect(find.text('노트 찾기, 화면 이동, 새 노트…'), findsOneWidget);
    tester.view.resetPhysicalSize();
  });
}
