import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:secondbrain/app/theme/app_theme.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:secondbrain/features/persona/persona_card.dart';
import 'package:secondbrain/features/persona/persona_form.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 페르소나 4문항 (설계서_프롬프트이후 5.2): 답을 고르고 [저장]하면 쓴 것만 넘기고, [건너뛰기]는 저장하지 않는다.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ShadApp(
        theme: buildAppTheme(Brightness.light),
        home: SingleChildScrollView(child: child),
      ),
    );
  }

  testWidgets('답 방식: 고른 쪽은 체크 표시가 붙어 안 고른 쪽과 분명히 다르다 (11/13 화면 검토)', (tester) async {
    await pump(tester, PersonaForm(initial: const Persona(), onSave: (p) async {}));
    Finder checkIn(String label) =>
        find.descendant(of: find.ancestor(of: find.text(label), matching: find.byType(ShadButton)), matching: find.byIcon(LucideIcons.check));
    expect(checkIn(Persona.styleShort), findsNothing);
    await tester.tap(find.text(Persona.styleShort));
    await tester.pump();
    expect(checkIn(Persona.styleShort), findsOneWidget);
    expect(checkIn(Persona.styleDetailed), findsNothing);
    await tester.tap(find.text(Persona.styleShort)); // 다시 누르면 고르지 않음
    await tester.pump();
    expect(checkIn(Persona.styleShort), findsNothing);
  });

  testWidgets('4문항을 채워 저장하면 쓴 그대로 넘긴다 (금지어는 쉼표·줄 모두)', (tester) async {
    Persona? saved;
    await pump(tester, PersonaForm(initial: const Persona(), onSave: (p) async => saved = p));
    expect(find.text('1. 지금 하는 일 한 줄'), findsOneWidget);
    expect(find.textContaining('나이'), findsNothing, reason: '나이·성별·건강·가족은 묻지 않는다');

    final fields = find.byType(EditableText);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '대림대 3학년, 맥 앱 개발');
    await tester.tap(find.text('개발 지식·해결법'));
    await tester.tap(find.text('수업·공부'));
    await tester.tap(find.text(Persona.styleShort));
    await tester.enterText(fields.at(1), '연봉, 집 주소\n돈');
    await tester.pump();
    expect(find.textContaining('1글자 단어("돈")는 검사하지 않습니다'), findsOneWidget);

    await tester.tap(find.text('저장'));
    await tester.pump();
    expect(saved, isNotNull);
    expect(saved!.work, '대림대 3학년, 맥 앱 개발');
    expect(saved!.keeps, ['개발 지식·해결법', '수업·공부'], reason: '보기 순서대로');
    expect(saved!.answerStyle, Persona.styleShort);
    expect(saved!.forbidden, ['연봉', '집 주소', '돈']);
  });

  testWidgets('저장된 답을 불러와 고치고, 고른 답 방식을 다시 누르면 비운다', (tester) async {
    Persona? saved;
    await pump(
      tester,
      PersonaForm(
        initial: const Persona(work: '카페 아르바이트', keeps: ['생활·기기'], answerStyle: Persona.styleDetailed, forbidden: ['병원']),
        onSave: (p) async => saved = p,
      ),
    );
    expect(find.text('카페 아르바이트'), findsOneWidget);
    await tester.tap(find.text('생활·기기'));
    await tester.tap(find.text(Persona.styleDetailed));
    await tester.tap(find.text('저장'));
    await tester.pump();
    expect(saved!.keeps, isEmpty);
    expect(saved!.answerStyle, '');
    expect(saved!.forbidden, ['병원']);
  });

  testWidgets('[건너뛰기]는 onSkip만 부르고, 없으면 버튼도 없다', (tester) async {
    var skipped = false;
    var saves = 0;
    await pump(tester, PersonaForm(initial: const Persona(), onSave: (_) async => saves++, onSkip: () => skipped = true));
    await tester.tap(find.text('건너뛰기'));
    expect((skipped, saves), (true, 0));

    await pump(tester, PersonaForm(initial: const Persona(), onSave: (_) async {}));
    expect(find.text('건너뛰기'), findsNothing);
  });

  testWidgets('저장이 실패하면 오류를 보이고 쓴 글은 그대로 둔다', (tester) async {
    await pump(tester, PersonaForm(initial: const Persona(), onSave: (_) async => throw const FileSystemExceptionStub()));
    await tester.enterText(find.byType(EditableText).first, '앱 개발');
    await tester.tap(find.text('저장'));
    await tester.pump();
    expect(find.textContaining('저장하지 못했습니다'), findsOneWidget);
    expect(find.text('앱 개발'), findsOneWidget);
  });

  testWidgets('[설정] 카드: 지식 폴더의 me.md를 채워 보이고, 고쳐 저장하면 파일에 쓴다', (tester) async {
    final temp = Directory.systemTemp.createTempSync('persona_card_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final vault = Vault(p.join(temp.path, 'vault'));
    const Persona(work: '맥 앱 개발', forbidden: ['연봉'], extra: '## 내 메모\n손으로 적음').save(vault);
    await pump(
      tester,
      ProviderScope(
        overrides: [vaultProvider.overrideWithValue(vault)],
        child: const PersonaCard(title: '나에 대해 (4문항)'),
      ),
    );
    expect(find.text('맥 앱 개발'), findsOneWidget);
    expect(find.text('연봉'), findsOneWidget);
    await tester.tap(find.text(Persona.styleDetailed));
    await tester.tap(find.text('저장'));
    await tester.pump();
    final saved = Persona.load(vault)!;
    expect(saved.answerStyle, Persona.styleDetailed);
    expect(saved.forbidden, ['연봉']);
    expect(File(vault.mePath).readAsStringSync(), contains('## 내 메모\n손으로 적음'));
  });
}

class FileSystemExceptionStub implements Exception {
  const FileSystemExceptionStub();

  @override
  String toString() => '쓰기 권한 없음';
}
