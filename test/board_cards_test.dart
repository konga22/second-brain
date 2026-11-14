import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secondbrain/app/theme/app_theme.dart';
import 'package:secondbrain/features/home/board_view.dart';
import 'package:secondbrain/features/home/decision_check_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 정리 보드 카드 (설계서_프롬프트이후 4.2·4.3·4.4). 화면 자체는 사람이 봐야 해서, 여기서는 보이는 글과 버튼이 넘기는 값만 본다.
void main() {
  IndexedDoc doc(String id, String title) => IndexedDoc(
    id: id,
    path: 'wiki/결제/$title.md',
    kind: 'note',
    title: title,
    summary: '',
    tags: '',
    status: NoteStatus.active,
    mtime: DateTime(2026, 11, 13),
    hash: 'abcdef123456',
  );

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    ShadApp(
      theme: buildAppTheme(Brightness.light),
      home: SizedBox(width: 360, child: SingleChildScrollView(child: child)),
    ),
  );

  testWidgets('4.2 정리 대기 카드: 비슷한 노트는 2개까지, [옆에 열기]·[합치기]가 그 노트를 넘긴다', (tester) async {
    String? opened;
    SimilarNote? merged;
    await pump(
      tester,
      DraftSimilarList(
        similar: [
          SimilarNote(doc: doc('n_0001', '결제 웹훅 재시도 규칙'), shared: 5, terms: 5),
          SimilarNote(doc: doc('n_0002', '웹훅 간격'), shared: 3, terms: 5),
          SimilarNote(doc: doc('n_0003', '세 번째는 안 보임'), shared: 3, terms: 5),
        ],
        onOpen: (id) => opened = id,
        onMerge: (s) => merged = s,
      ),
    );
    expect(find.text('비슷한 정리된 노트'), findsOneWidget);
    expect(find.text('결제 웹훅 재시도 규칙  (5/5)'), findsOneWidget);
    expect(find.textContaining('세 번째는 안 보임'), findsNothing);
    await tester.tap(find.text('옆에 열기').first);
    expect(opened, 'n_0001');
    await tester.tap(find.text('합치기').last);
    expect(merged!.doc.id, 'n_0002');
  });

  testWidgets('화면 검토: 좁은 칸(230px)에서도 비슷한 노트 제목이 버튼에 밀려 몇 글자로 줄지 않는다', (tester) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildAppTheme(Brightness.light),
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 230,
            child: DraftSimilarList(
              similar: [SimilarNote(doc: doc('n_0001', 'FTS5 trigram 토크나이저로 한국어 검색'), shared: 3, terms: 5)],
              onOpen: (_) {},
              onMerge: (_) {},
            ),
          ),
        ),
      ),
    );
    final title = find.text('FTS5 trigram 토크나이저로 한국어 검색  (3/5)');
    expect(title, findsOneWidget);
    expect(tester.getSize(title).width, greaterThan(200), reason: '제목은 칸 폭을 다 쓴다');
    // 버튼은 제목 아래 줄
    expect(tester.getTopLeft(find.text('합치기')).dy, greaterThan(tester.getBottomLeft(title).dy - 1));
  });

  /// 버튼이 흐리게(꺼짐) 보이는지: shadcn은 enabled가 false일 때만 반투명으로 그린다.
  bool looksDisabled(WidgetTester tester, String label) => tester
      .widgetList<Opacity>(find.ancestor(of: find.text(label), matching: find.byType(Opacity)))
      .any((o) => o.opacity < 1);

  AiEdit edit({bool canRevert = true}) => AiEdit(
    noteId: 'n_0007',
    title: '로그인 토큰 만료 시간',
    batches: const ['b_20261113-140500-a1b2', 'b_20261113-141000-c3d4'],
    firstAt: DateTime(2026, 11, 13, 14, 5),
    lastAt: DateTime(2026, 11, 13, 14, 10),
    sessions: const {'7d1c2b3a-1111-4222-8333-444455556666'},
    canRevert: canRevert,
  );

  testWidgets('4.3 AI가 고친 노트: 언제·어느 대화·몇 번, 버튼 셋이 각자 동작한다', (tester) async {
    final pressed = <String>[];
    await pump(
      tester,
      Column(
        children: [
          Text(aiEditDetail(edit())),
          AiEditActions(
            edit: edit(),
            onShowDiff: () => pressed.add('diff'),
            onRevert: () => pressed.add('revert'),
            onAcknowledge: () => pressed.add('ack'),
          ),
        ],
      ),
    );
    expect(find.text('11/13 14:10 · 대화 7d1c2b3a · 2번 고침'), findsOneWidget);
    await tester.tap(find.text('바뀐 내용 보기'));
    await tester.tap(find.text('되돌리기'));
    await tester.tap(find.text('확인함'));
    expect(pressed, ['diff', 'revert', 'ack']);
  });

  testWidgets('4.3 AI가 고친 뒤 사람이 또 고쳤으면 [되돌리기]가 눌리지 않고 까닭을 보인다', (tester) async {
    var reverted = false;
    await pump(
      tester,
      AiEditActions(edit: edit(canRevert: false), onShowDiff: () {}, onRevert: () => reverted = true, onAcknowledge: () {}),
    );
    await tester.tap(find.text('되돌리기'), warnIfMissed: false);
    expect(reverted, isFalse);
    expect(find.textContaining('직접 고친 기록이 있어'), findsOneWidget);
    expect(looksDisabled(tester, '되돌리기'), isTrue, reason: '눌리지 않는 버튼은 흐리게 보인다');
    expect(looksDisabled(tester, '확인함'), isFalse);
  });

  testWidgets('4.3 바뀐 내용 보기: 빠진 줄은 -, 새 줄은 +', (tester) async {
    await pump(tester, DiffLines(lines: lineDiff('제목\n액세스 15분\n끝', '제목\n액세스 30분\n끝')));
    expect(find.text('- 액세스 15분'), findsOneWidget);
    expect(find.text('+ 액세스 30분'), findsOneWidget);
    expect(find.text('  제목'), findsOneWidget);
  });

  testWidgets('4.4 (나) 점검 줄: 마지막 점검·진행·오류, 도는 중에는 [지금 점검]이 눌리지 않는다', (tester) async {
    var runs = 0;
    await pump(tester, DecisionCheckBar(state: DecisionCheckState(lastRunAt: DateTime(2026, 11, 13)), onRun: () => runs++));
    expect(find.text('옛 결정 점검: 11/13 (주 1회)'), findsOneWidget);
    await tester.tap(find.text('지금 점검'));
    expect(runs, 1);
    expect(looksDisabled(tester, '지금 점검'), isFalse);

    await pump(tester, DecisionCheckBar(state: const DecisionCheckState(isRunning: true, done: 120, total: 300), onRun: () => runs++));
    expect(find.text('옛 결정 점검 중 120/300'), findsOneWidget);
    await tester.tap(find.text('지금 점검'), warnIfMissed: false);
    expect(runs, 1, reason: '도는 중에는 다시 돌리지 않는다');
    expect(looksDisabled(tester, '지금 점검'), isTrue, reason: '도는 중에는 흐리게 보인다');

    await pump(tester, DecisionCheckBar(state: const DecisionCheckState(error: 'database is locked'), onRun: () {}));
    expect(find.text('옛 결정 점검 실패: database is locked'), findsOneWidget);
  });

  testWidgets('4.4 (나) 옛 결정일 수 있음: [옛 노트 보관]·[둘 다 맞음]·[열어 보기]', (tester) async {
    final pressed = <String>[];
    await pump(
      tester,
      OldDecisionActions(
        onArchive: () => pressed.add('archive'),
        onKeepBoth: () => pressed.add('keep'),
        onOpen: () => pressed.add('open'),
      ),
    );
    await tester.tap(find.text('옛 노트 보관'));
    await tester.tap(find.text('둘 다 맞음'));
    await tester.tap(find.text('열어 보기'));
    expect(pressed, ['archive', 'keep', 'open']);
  });
}
