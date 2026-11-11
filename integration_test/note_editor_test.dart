import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:secondbrain/features/notes/note_editor_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 노트 편집 대화상자가 바깥 클릭·ESC 한 번에 닫혀 쓴 글이 사라지던 것 (11/11 기능검토 K-24).
///
/// BRAIN_VAULT=<사본> BRAIN_CONFIG=<임시 파일> flutter test integration_test/note_editor_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
  }

  testWidgets('쓰던 글은 바깥 클릭·ESC로 사라지지 않고, 버릴지 묻는다', (tester) async {
    expect(Platform.environment['BRAIN_VAULT'] ?? '', isNotEmpty, reason: '실제 지식 폴더 보호');
    expect(Platform.environment['BRAIN_CONFIG'] ?? '', isNotEmpty, reason: '실제 설정 보호');
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    await settle(tester, 3000);
    final container = ProviderScope.containerOf(tester.element(find.byType(SecondBrainApp)));

    // ⌘N: 새 노트
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await settle(tester);
    expect(find.text('새 노트'), findsOneWidget);
    final inputs = find.descendant(of: find.byType(ShadDialog), matching: find.byType(EditableText));
    await tester.enterText(inputs.at(0), '편집 대화상자 시험 노트');
    await tester.enterText(inputs.at(1), '바깥 클릭에 안 사라지는지');
    await tester.enterText(inputs.last, '쓰던 본문');
    await settle(tester, 300);

    // 1) 대화상자 바깥(왼쪽 위 구석)을 누른다 — 고치기 전에는 여기서 닫혔다
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    expect(find.text('새 노트'), findsOneWidget, reason: '바깥 클릭으로 닫히면 안 된다');

    // 2) 본문을 쓰던 중 ESC — 바로 닫히지 않고 버릴지 묻는다
    await tester.tap(inputs.last);
    await settle(tester, 300);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.text('저장하지 않고 닫을까요?'), findsOneWidget);
    await tester.tap(find.text('계속 쓰기'));
    await settle(tester);
    expect(find.text('새 노트'), findsOneWidget);
    expect(find.text('쓰던 본문'), findsOneWidget, reason: '계속 쓰기를 누르면 글이 그대로 있어야 한다');

    // 3) 저장하면 묻지 않고 닫히고 노트가 생긴다
    await tester.tap(find.text('저장'));
    await settle(tester, 1500);
    expect(find.text('새 노트'), findsNothing);
    expect(find.text('저장하지 않고 닫을까요?'), findsNothing);
    final notes = container.read(notesProvider);
    expect(notes.map((d) => d.title), contains('편집 대화상자 시험 노트'));

    // 4) 아무것도 안 쓰고 [취소]는 묻지 않고 바로 닫힌다
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await settle(tester);
    await tester.tap(find.text('취소'));
    await settle(tester);
    expect(find.text('새 노트'), findsNothing);
    expect(find.text('저장하지 않고 닫을까요?'), findsNothing);

    // 5) 고치는 사이 밖(CLI·AI)에서 같은 노트가 바뀌면: 저장 → 충돌 → [내 것으로 덮어쓰기]로 저장된다 (11/11 K-34)
    final id = container.read(notesProvider).firstWhere((d) => d.title == '편집 대화상자 시험 노트').id;
    final navigator = tester.element(find.byType(Navigator).first);
    unawaited(showNoteEditor(navigator, noteId: id));
    await settle(tester);
    final editInputs = find.descendant(of: find.byType(ShadDialog), matching: find.byType(EditableText));
    await tester.enterText(editInputs.last, '앱에서 고친 본문');
    await settle(tester, 300);
    final store = container.read(noteStoreProvider);
    final (_, outside, outsideHash) = store.read(id)!;
    store.write(id, '${outside.body}\nCLI가 덧붙인 줄\n', expectHash: outsideHash);
    await tester.tap(find.text('저장'));
    await settle(tester, 1500);
    expect(find.text('내 것으로 덮어쓰기'), findsOneWidget, reason: '충돌이면 다시 저장할 길이 보여야 한다');
    expect(find.text('최신 내용 불러오기'), findsOneWidget);
    await tester.tap(find.text('내 것으로 덮어쓰기'));
    await settle(tester, 1500);
    expect(find.text('내 것으로 덮어쓰기'), findsNothing);
    expect(store.read(id)!.$2.body.trim(), '앱에서 고친 본문');
    expect(container.read(conflictCountProvider), greaterThan(0), reason: '충돌 사본 수가 바로 보여야 한다');
    tester.view.resetPhysicalSize();
  });
}
