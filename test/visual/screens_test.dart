import 'package:brain_core/brain_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secondbrain/app/router/app_page.dart';
import 'package:secondbrain/core/background_tasks.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:secondbrain/features/connect/connect_page.dart';
import 'package:secondbrain/features/connect/system_check_provider.dart';
import 'package:secondbrain/features/home/home_page.dart';
import 'package:secondbrain/features/home/neural_view.dart';
import 'package:secondbrain/features/lessons/lessons_page.dart';
import 'package:secondbrain/features/notes/folder_tidy_dialog.dart';
import 'package:secondbrain/features/notes/notes_page.dart';
import 'package:secondbrain/features/settings/settings_page.dart';
import 'package:secondbrain/shared/app_shell.dart';
import 'package:secondbrain/shared/sidebar.dart';

import 'visual_harness.dart';

/// 새 화면을 PNG로 뽑는다 (사람이 눈으로 보는 용도, 판정 없음). 실행 방법은 visual_harness.dart 맨 위.
void main() {
  late Fixture fx;

  setUpAll(loadAppFonts);
  setUp(() => fx = Fixture.create());
  tearDown(() => fx.dispose());

  const window = Size(1440, 900);
  const both = [Brightness.light, Brightness.dark];
  String tag(Brightness b) => b == Brightness.dark ? 'dark' : 'light';

  Future<SystemCheck> systemCheck(WidgetTester tester) async {
    late SystemCheck check;
    await tester.runAsync(() async {
      check = SystemCheck(sqlite: checkSqliteSupport(), vault: await checkVaultAccess(fx.vault.root), isSupabaseReachable: null);
    });
    return check;
  }

  Future<NeuralLayout> neuralOf(WidgetTester tester) async {
    late NeuralLayout layout;
    final notes = fx.index.notes();
    await tester.runAsync(() async {
      layout = await neuralLayoutInBackground(
        fx.vault.root,
        fx.vault.indexPath,
        [
          for (final d in notes)
            if (!d.isMerged) (id: d.id, path: d.path, title: d.title, topic: d.topicPath, isDraft: d.isDraft),
        ],
        [
          for (final l in fx.links())
            if (!l.isSuggested) (l.fromId, l.toId),
        ],
      );
    });
    return layout;
  }

  for (final b in both) {
    visualTest('1 설정: 나에 대해(4문항)·이전 방식 카드 (${tag(b)})', (tester) async {
      fx.fillStandard();
      const Persona(
        work: '대림대 3학년, 맥 앱(세컨드 브레인) 개발',
        keeps: ['프로젝트 결정·구조', '개발 지식·해결법'],
        answerStyle: Persona.styleShort,
        forbidden: ['연봉', '집 주소'],
      ).save(fx.vault);
      setSurface(tester, const Size(1440, 1950));
      final check = await systemCheck(tester);
      await pumpApp(
        tester,
        brightness: b,
        overrides: fx.overrides(
          systemCheck: check,
          config: AppConfig(
            isFirstRunDone: true,
            panelWidth: 380,
            lastBackupAt: DateTime.now().subtract(const Duration(days: 9)),
            legacy: const {AppConfig.legacyLessons},
          ),
        ),
        child: const AppShell(current: AppPage.settings, child: SettingsPage()),
      );
      await capture(tester, '01_settings_${tag(b)}');
    });

    visualTest('2 연동: 4문항 단계 (${tag(b)})', (tester) async {
      fx.fillStandard();
      setSurface(tester, const Size(1440, 1700));
      final check = await systemCheck(tester);
      await pumpApp(
        tester,
        brightness: b,
        overrides: fx.overrides(systemCheck: check),
        child: const AppShell(current: AppPage.connect, child: ConnectPage()),
      );
      expect(find.text('다음 단계: 나에 대해 4문항 (선택)'), findsOneWidget);
      await capture(tester, '02_connect_persona_${tag(b)}');
    });

    visualTest('3 배운 것: 합치기 필요 + 합치기 창 (${tag(b)})', (tester) async {
      fx.fillStandard();
      fx.fillLessons();
      setSurface(tester, window);
      final check = await systemCheck(tester);
      await pumpApp(
        tester,
        brightness: b,
        overrides: fx.overrides(systemCheck: check),
        child: const AppShell(current: AppPage.lessons, child: LessonsPage()),
      );
      expect(find.text('합치기 필요'), findsOneWidget);
      await capture(tester, '03a_lessons_merge_notice_${tag(b)}');
      await tester.tap(find.text('합치기').first);
      await settle(tester);
      expect(find.text('규칙 합치기'), findsOneWidget);
      await capture(tester, '03b_lessons_merge_dialog_${tag(b)}');
    });

    visualTest('4 정리 보드: 초안 비슷한 노트·AI가 고친 노트·옛 결정 (${tag(b)})', (tester) async {
      fx.fillStandard();
      setSurface(tester, window);
      final check = await systemCheck(tester);
      final container = await pumpApp(
        tester,
        brightness: b,
        overrides: fx.overrides(systemCheck: check),
        child: const AppShell(current: AppPage.home, child: HomePage()),
      );
      await tester.tap(find.text('정리 보드'));
      await settle(tester);
      container.read(selectedNoteProvider.notifier).select(fx.ids['결제 웹훅 재시도 간격 정리']);
      await settle(tester);
      await capture(tester, '04_board_${tag(b)}');
    });

    visualTest('5 폴더 정리 창 (${tag(b)})', (tester) async {
      fx.fillStandard();
      setSurface(tester, window);
      final check = await systemCheck(tester);
      await pumpApp(
        tester,
        brightness: b,
        overrides: fx.overrides(systemCheck: check),
        child: const AppShell(current: AppPage.notes, child: NotesPage()),
      );
      // 사이드바의 [폴더 정리] 버튼과 같은 함수
      final opened = showFolderTidy(tester.element(find.byType(Sidebar)));
      await tester.pump();
      for (var i = 0; i < 40 && find.text('제안을 만드는 중…').evaluate().isNotEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      await settle(tester);
      expect(find.text('폴더 정리'), findsWidgets);
      await capture(tester, '05_folder_tidy_${tag(b)}');
      opened.ignore();
    });

    visualTest('6·7 사이드바 구역/주제 + 노트 패널 사진 (${tag(b)})', (tester) async {
      setSurface(tester, window);
      final png = await makeSamplePng(tester, fx.temp.path);
      fx.fillStandard(imagePath: png);
      final check = await systemCheck(tester);
      final container = await pumpApp(
        tester,
        brightness: b,
        overrides: fx.overrides(systemCheck: check, config: const AppConfig(isFirstRunDone: true, panelWidth: 520)),
        child: const AppShell(current: AppPage.notes, child: NotesPage()),
      );
      container.read(selectedNoteProvider.notifier).select(fx.ids['릴리스 빌드 서명 오류 해결']);
      await settle(tester);
      // 사진 디코딩: flutter_tester에서 멈출 수 있어(11/13 기록) 시간 제한을 둔다
      final images = find.byType(Image);
      var decoded = 'no-image-widget';
      if (images.evaluate().isNotEmpty) {
        final image = tester.widget<Image>(images.first);
        await tester.runAsync(() async {
          try {
            await precacheImage(image.image, tester.element(images.first)).timeout(const Duration(seconds: 8));
            decoded = 'ok';
          } on Object catch (e) {
            decoded = 'failed: $e';
          }
        });
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pump();
        }
      }
      final raw = find.byType(RawImage);
      final isPainted = raw.evaluate().isNotEmpty && tester.renderObject<RenderImage>(raw.first).image != null;
      // ignore: avoid_print
      print('[visual] 노트 패널 사진: 미리 읽기 $decoded, 그려짐 $isPainted');
      await capture(tester, '06_07_sidebar_notepanel_image_${tag(b)}');
    });

    visualTest('8a 신경망: 기본·긴 제목 노트 고름 (${tag(b)})', (tester) async {
      fx.fillStandard();
      setSurface(tester, window);
      final check = await systemCheck(tester);
      final neural = await neuralOf(tester);
      final container = await pumpApp(
        tester,
        brightness: b,
        overrides: fx.overrides(systemCheck: check, neural: neural),
        child: const AppShell(current: AppPage.home, child: HomePage()),
      );
      await tester.tap(find.text('신경망'));
      await settle(tester);
      await capture(tester, '08a_neural_default_${tag(b)}');
      container.read(selectedNoteProvider.notifier).select(fx.ids['Claude Code 압축 훅 3가지 — 압축 전 지시·압축 요약 받기·압축 뒤 주입까지 한 번에 정리한 노트']);
      await settle(tester);
      await capture(tester, '08b_neural_selected_long_title_${tag(b)}');
      container.read(selectedNoteProvider.notifier).select(fx.ids['외장 디스크가 빠졌을 때 빈 폴더를 만들어 색인을 비우던 문제와 시작 점검 순서 (K-33)']);
      await settle(tester);
      await capture(tester, '08c_neural_selected_long_title2_${tag(b)}');

      // 마우스 올림: 평소 한 줄로 줄인 긴 제목이 전체로 (고르기 전)
      container.read(selectedNoteProvider.notifier).select(null);
      await settle(tester);
      final view = tester.getRect(find.byType(NeuralView));
      const longTitle = 'Claude Code 압축 훅 3가지 — 압축 전 지시·압축 요약 받기·압축 뒤 주입까지 한 번에 정리한 노트';
      final i = neural.indexOfNote(fx.ids[longTitle]!)!;
      // _Geo와 같은 셈 (확대 1배): 층 위 92, 아래 48, 은닉층 x는 입력·출력층 가운데
      final xIn = (view.width * 0.2).clamp(92, 200).roundToDouble();
      final xOut = (view.width - (view.width * 0.18).clamp(84, 170)).roundToDouble();
      final xH = ((xIn + xOut) / 2).roundToDouble();
      final y = 92 + (i + 0.5) * (view.height - 92 - 48) / neural.notes.length;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: view.topLeft);
      await mouse.moveTo(view.topLeft + Offset(xH, y));
      await settle(tester);
      await capture(tester, '08f_neural_hover_long_title_${tag(b)}');
      await mouse.moveTo(view.topLeft + const Offset(4, 4));
      await mouse.removePointer();
      await settle(tester);

      // 확대: 겹쳐서 빠졌던 노트 이름표가 나온다
      for (var k = 0; k < 3; k++) {
        await tester.tap(find.text('+'));
        await tester.pump();
      }
      await settle(tester);
      await capture(tester, '08g_neural_zoom_${tag(b)}');
    });
  }

  visualTest('8d 신경망: 노트 1,000개 합성 폴더 (기본·고름)', (tester) async {
    setSurface(tester, window);
    final big = syntheticVault(1000);
    final check = await systemCheck(tester);
    final container = await pumpApp(
      tester,
      brightness: Brightness.dark,
      overrides: fx.overrides(systemCheck: check, neural: big.layout, notes: big.notes, links: big.links),
      child: const AppShell(current: AppPage.home, child: HomePage()),
    );
    await tester.tap(find.text('신경망'));
    await settle(tester);
    await capture(tester, '08d_neural_1000_default');
    container.read(selectedNoteProvider.notifier).select(big.notes[123].id);
    await settle(tester);
    await capture(tester, '08e_neural_1000_selected');
  });
}
