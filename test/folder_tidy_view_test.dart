import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secondbrain/app/theme/app_theme.dart';
import 'package:secondbrain/features/notes/folder_tidy_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// [폴더 정리] 목록 (설계서_프롬프트이후 5.1). 화면 모양은 사람이 봐야 해서, 보이는 글과 [옮기기]가 넘기는 값만 본다.
void main() {
  FolderProposal proposal(String id, String from, String topic, String name) => FolderProposal(
    id: id,
    title: '$name 긴 제목',
    from: from,
    topic: topic,
    name: name,
    reason: '시험 까닭',
  );

  final proposals = [
    proposal('n_0001', 'wiki/세컨드브레인 개발/a.md', '프로젝트/세컨드브레인', '설계 결정'),
    proposal('n_0002', 'wiki/세컨드브레인 개발/b.md', '개발 지식/Flutter', '플러터 오류'),
    proposal('n_0003', 'wiki/맥 관리/c.md', '생활·기기/맥 관리', '디스크 정리'),
  ];

  Future<List<List<FolderMove>>> pump(WidgetTester tester, {Map<String, int> oversized = const {}}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final runs = <List<FolderMove>>[];
    await tester.pumpWidget(
      ShadApp(
        theme: buildAppTheme(Brightness.light),
        home: SizedBox(
          width: 1000,
          height: 800,
          child: FolderTidyView(proposals: proposals, oversized: oversized, onRun: runs.add),
        ),
      ),
    );
    return runs;
  }

  testWidgets('지금 주제별로 묶어 노트 / 지금 자리 / 제안 자리 / 제안 이름을 보이고, 모두 옮기기', (tester) async {
    final runs = await pump(tester, oversized: {'프로젝트/세컨드브레인': 41});
    expect(find.text('세컨드브레인 개발 · 2개'), findsOneWidget);
    expect(find.text('맥 관리 · 1개'), findsOneWidget);
    expect(find.text('→ 개발 지식/Flutter / 플러터 오류.md'), findsOneWidget);
    expect(find.text('wiki/맥 관리/c.md'), findsOneWidget);
    expect(find.textContaining('41개입니다'), findsOneWidget); // 30개 넘는 주제 나누기 제안
    await tester.tap(find.text('고른 3개 옮기기'));
    expect(runs.single.map((m) => (m.id, m.topic, m.name)), [
      ('n_0001', '프로젝트/세컨드브레인', '설계 결정'),
      ('n_0002', '개발 지식/Flutter', '플러터 오류'),
      ('n_0003', '생활·기기/맥 관리', '디스크 정리'),
    ]);
  });

  testWidgets('골라서 승인: 체크를 끈 노트는 옮기지 않는다', (tester) async {
    final runs = await pump(tester);
    await tester.tap(find.byType(ShadCheckbox).at(1));
    await tester.pump();
    await tester.tap(find.text('고른 2개 옮기기'));
    expect(runs.single.map((m) => m.id), ['n_0001', 'n_0003']);
  });

  testWidgets('주제째 자리 바꾸기: 모르는 구역은 거절, 구역/주제면 그 주제 노트 모두에', (tester) async {
    final runs = await pump(tester);
    await tester.tap(find.text('이 주제 자리 바꾸기').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, '개발/모음');
    await tester.tap(find.text('바꾸기').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('없는 구역'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).first, '프로젝트/세컨드브레인 앱');
    await tester.tap(find.text('바꾸기').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('고른 3개 옮기기'));
    expect(runs.single.take(2).map((m) => m.topic), ['프로젝트/세컨드브레인 앱', '프로젝트/세컨드브레인 앱']);
    expect(runs.single.last.topic, '생활·기기/맥 관리');
  });

  testWidgets('옮기는 중: 진행과 오류를 보이고 버튼은 잠근다', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ShadApp(
        theme: buildAppTheme(Brightness.light),
        home: SizedBox(
          width: 1000,
          height: 800,
          child: FolderTidyView(
            proposals: proposals,
            onRun: (_) => fail('옮기는 중에는 누를 수 없다'),
            isRunning: true,
            done: 200,
            total: 1000,
            errors: const [(id: 'n_0009', message: 'n_0009 노트가 없습니다.')],
          ),
        ),
      ),
    );
    expect(find.text('200/1000 옮기는 중…'), findsOneWidget);
    expect(find.text('· n_0009: n_0009 노트가 없습니다.'), findsOneWidget);
    await tester.tap(find.text('고른 3개 옮기기'), warnIfMissed: false); // 잠긴 버튼이라 눌리지 않는다
  });
}
