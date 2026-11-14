import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:brain_core/brain_core.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:secondbrain/app/theme/app_theme.dart';
import 'package:secondbrain/core/app_config_provider.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:secondbrain/core/claude_code.dart';
import 'package:secondbrain/features/connect/auto_tidy.dart';
import 'package:secondbrain/features/connect/claude_code_providers.dart';
import 'package:secondbrain/features/connect/system_check_provider.dart';
import 'package:secondbrain/features/home/decision_check_provider.dart';
import 'package:secondbrain/features/home/neural_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 화면 그림(PNG) 뽑기 도구. 사람이 화면을 직접 볼 수 없을 때(화면 기록 권한 없음) 위젯 시험으로 그려 파일로 남긴다.
///
/// 실행 (사용자 지식 폴더·설정·색인 캐시·Claude 기록을 건드리지 않게 HOME을 임시 폴더로 바꾼다):
///   VISUAL_OUT=/tmp/sb_screens HOME=$(mktemp -d) PUB_CACHE=~/.pub-cache BRAIN_CONFIG=/tmp/sb_screens/config.json \
///     flutter test test/visual/
/// (PUB_CACHE는 바꾸기 전 HOME 기준 경로를 그대로 적는다.) VISUAL_OUT이 없으면 시험을 건너뛴다 (보통 `flutter test`에서는 돌지 않음).
/// 화면 오류(넘침 등)는 멈추지 않고 VISUAL_OUT/_errors.txt에 모은다.
String? get visualOut => Platform.environment['VISUAL_OUT'];

final shotKey = GlobalKey();

const systemFamily = 'VisualSystemSF';
const hangulFallback = 'VisualAppleSDGothicNeo';

/// 앱의 기본 글자(시스템 글꼴) 대신. 한글·고정폭(Menlo) 글의 한글도 이 대체 글꼴로 나온다 (macOS와 같음).
const systemTextStyle = TextStyle(fontFamily: systemFamily, fontFamilyFallback: [hangulFallback]);

/// 앱이 쓰는 글꼴을 읽어 둔다. flutter_tester는 글꼴을 저절로 읽지 않아 모든 글자가 네모로 그려진다.
Future<void> loadAppFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final file = File(f);
      if (!file.existsSync()) continue;
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }

  const pretendard = 'assets/fonts/pretendard';
  await load('Pretendard', [
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) '$pretendard/Pretendard-$w.otf',
  ]);
  // 글꼴을 지정하지 않은 글(TextStyle에 family 없음)은 앱에서 macOS 시스템 글꼴(SF + 한글은 Apple SD Gothic Neo)로 나온다.
  // flutter_tester는 그 자리에 네모 시험 글꼴을 써서, 같은 시스템 글꼴 파일을 읽어 [systemTextStyle]로 깔아 준다.
  await load(systemFamily, ['/System/Library/Fonts/SFNS.ttf']);
  await load(hangulFallback, ['/System/Library/Fonts/AppleSDGothicNeo.ttc']);
  final packages = _packageRoots();
  final lucide = packages['lucide_icons_flutter'];
  if (lucide != null) {
    await load('packages/lucide_icons_flutter/Lucide', ['$lucide/assets/lucide.ttf']);
    for (final w in [100, 200, 300, 400, 500, 600]) {
      await load('packages/lucide_icons_flutter/Lucide$w', ['$lucide/assets/build_font/LucideVariable-w$w.ttf']);
    }
  }
  final shad = packages['shadcn_ui'];
  if (shad != null) {
    await load('packages/shadcn_ui/Geist', ['$shad/fonts/Geist[wght].ttf']);
    await load('packages/shadcn_ui/GeistMono', ['$shad/fonts/GeistMono[wght].ttf']);
  }
  // 앱의 고정폭 글자(노트 번호·diff)는 macOS Menlo. 한글은 앱에서는 시스템 대체 글꼴로 나오지만 여기서는 네모로 나올 수 있다.
  await load('Menlo', ['/System/Library/Fonts/Menlo.ttc']);
}

Map<String, String> _packageRoots() {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return const {};
  final text = config.readAsStringSync();
  final out = <String, String>{};
  for (final m in RegExp(r'"name":\s*"([^"]+)",\s*"rootUri":\s*"([^"]+)"').allMatches(text)) {
    var root = m.group(2)!;
    if (root.startsWith('file://')) root = Uri.parse(root).toFilePath();
    out[m.group(1)!] = root;
  }
  return out;
}

/// 창 크기 (논리 픽셀)와 배율.
void setSurface(WidgetTester tester, Size logical, {double dpr = 2}) {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
  addTearDown(tester.view.reset);
}

/// [shotKey] 아래를 PNG로 쓴다.
Future<String> capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
  final path = p.join(visualOut!, '$name.png');
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  return path;
}

/// 메모리 설정: 파일에 쓰지 않는다.
class MemoryConfig extends AppConfigNotifier {
  MemoryConfig(this.initial);

  final AppConfig initial;

  @override
  AppConfig build() => initial;

  @override
  void update(AppConfig Function(AppConfig) change, {bool save = true}) => super.update(change, save: false);
}

/// 폴더 감시·시작 동기화 없이 번호만.
class StillRevision extends VaultRevision {
  @override
  int build() => 0;

  @override
  void bump() => state++;
}

class StillDecisionCheck extends DecisionCheckController {
  StillDecisionCheck(this.initial);

  final DecisionCheckState initial;

  @override
  DecisionCheckState build() => initial;
}

class StillAutoTidy extends AutoTidyController {
  @override
  AutoTidyState build() => const AutoTidyState();
}

/// 시험용 지식 폴더 (임시 폴더). 노트는 앱과 같은 [NoteStore]로 만든다.
class Fixture {
  Fixture._(this.temp, this.vault, this.index);

  final Directory temp;
  final Vault vault;
  final SearchIndex index;

  final ids = <String, String>{}; // 제목 → id

  static Fixture create() {
    final temp = Directory.systemTemp.createTempSync('sb_visual_');
    final vault = Vault(p.join(temp.path, 'SecondBrain'))..ensure();
    // 색인은 앱과 같은 자리(HOME/Library/Caches/…). 백그라운드 작업(isolate)이 같은 파일을 연다.
    final index = SearchIndex.open(vault);
    return Fixture._(temp, vault, index);
  }

  void dispose() {
    index.close();
    temp.deleteSync(recursive: true);
    final cache = Directory(p.dirname(vault.indexPath));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  }

  NoteStore get zoned => NoteStore(vault, index);

  NoteStore get legacy => NoteStore(vault, index, zoned: false);

  void raw(String rel, String id, String title, {String body = '대화 기록'}) {
    File(p.join(vault.root, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('---\nid: $id\ntitle: "$title"\nsource: session\n---\n\n$body\n');
  }

  String add(
    String topic,
    String title,
    String summary,
    String body, {
    bool draft = false,
    bool isLegacy = false,
    List<String> sources = const [],
    List<String> tags = const [],
    List<String> attachments = const [],
  }) {
    if (!isLegacy) zoned.createTopic(topic);
    final (id, _) = (isLegacy ? legacy : zoned).add(
      title: title,
      summary: summary,
      body: body,
      topic: topic,
      draft: draft,
      source: sources.isEmpty ? 'manual' : 'session',
      sources: sources,
      tags: tags,
      attachments: attachments,
    );
    ids[title] = id;
    return id;
  }

  /// 프로젝트를 하는 학생의 지식 폴더처럼 채운다.
  void fillStandard({String? imagePath}) {
    const s1 = 'raw/sessions/2026-11-10-7d1c2b3a.md';
    const s2 = 'raw/sessions/2026-11-12-a91f02cc.md';
    const s3 = 'raw/sessions/2026-11-13-5e0b77d1.md';
    const imp = 'raw/imports/2026-11-07-오픈소스-조사.md';
    raw(s1, 'r_7d1c2b3a', '신경망 보기 구현 대화');
    raw(s2, 'r_a91f02cc', '폴더 구조 5.1 옮기기 대화');
    raw(s3, 'r_5e0b77d1', '정리 보드 카드 다듬기 대화');
    raw(imp, 'r_import01', '참고 레포 조사 문서');

    add(
      '프로젝트/세컨드브레인',
      '지식은 md 원본과 SQLite FTS5 색인으로 둔다',
      '임베딩 없이 FTS5만',
      'md 파일이 원본이고 색인은 캐시다. [[FTS5 trigram 토크나이저로 한국어 검색]]',
      sources: [s1],
    );
    add(
      '프로젝트/세컨드브레인',
      '구역/주제 2단 폴더 구조 (5.1)',
      '구역 5개 아래 주제',
      '프로젝트·개발 지식·조사·참고·공부·생활·기기 구역 아래 주제 폴더. [[지식은 md 원본과 SQLite FTS5 색인으로 둔다]]',
      sources: [s2],
    );
    add('프로젝트/세컨드브레인', '요금제·사용량 판단은 Edge Function에서', '서버에서만 판단', 'AI API 키는 Supabase 환경변수에만 둔다.', sources: [s1]);
    add(
      '프로젝트/세컨드브레인',
      'Claude Code 압축 훅 3가지 — 압축 전 지시·압축 요약 받기·압축 뒤 주입까지 한 번에 정리한 노트',
      '압축 전후 훅',
      'PreCompact, 요약 받기, SessionStart(compact) 주입. [[신경망 보기 이름표는 자르지 않는다]]',
      sources: [s1],
    );
    add('프로젝트/세컨드브레인', '신경망 보기 이름표는 자르지 않는다', '긴 제목은 여러 줄로', '말줄임 없이 줄을 바꿔 다 보인다.', sources: [s1]);
    add(
      '프로젝트/세컨드브레인',
      '외장 디스크가 빠졌을 때 빈 폴더를 만들어 색인을 비우던 문제와 시작 점검 순서 (K-33)',
      '시작 점검 순서',
      '폴더를 만들지 않고 먼저 확인한다. [[database is locked 피하기 (busy_timeout)]]',
      sources: [s2],
    );
    add('개발 지식/Flutter', 'Riverpod 3 Notifier 오버라이드 방법', 'overrideWith(Sub.new)', '시험에서 Notifier를 하위 클래스로 바꾼다.', sources: [s3]);
    add('개발 지식/Flutter', 'macOS 샌드박스에서 파일 접근 권한', '보안 범위 북마크', 'file_selector로 고른 폴더는 북마크로 남긴다.');
    add('개발 지식/Flutter', 'flutter_tester에서 이미지 디코딩이 멈춤', 'runAsync 주의', '위젯 트리까지만 본다. [[Riverpod 3 Notifier 오버라이드 방법]]', sources: [s3]);
    add('개발 지식/Flutter', 'shadcn_ui 다이얼로그 너비 지정', 'constraints maxWidth', 'ShadDialog(constraints: BoxConstraints(maxWidth: 980)).');
    add('개발 지식/SQLite', 'FTS5 trigram 토크나이저로 한국어 검색', '2글자 이하 LIKE 대체', 'trigram은 3글자부터 잡힌다.', sources: [imp]);
    add('개발 지식/SQLite', 'database is locked 피하기 (busy_timeout)', '쓰기 대기 5초', 'busy_timeout을 두고 같은 줄에 세운다.', sources: [s2]);
    add('개발 지식/Git', '커밋 전에 사용자 허락을 받는다', '허락 없이 커밋 금지', '커밋·push 전에 먼저 묻는다.');
    add('개발 지식/Git', 'push 대상 브랜치를 먼저 확인한다', '보호 브랜치 사고 방지', 'git branch --show-current로 확인.');
    add('조사·참고/오픈소스', 'Obsidian 그래프 뷰 참고', '힘 배치 그래프', '노드 크기는 연결 수.', sources: [imp]);
    add('조사·참고/오픈소스', 'Logseq 블록 구조 조사', '블록 단위 참조', '우리는 노트 단위로 둔다.', sources: [imp]);
    add('공부/운영체제', '프로세스와 스레드 차이', '주소 공간 공유 여부', '스레드는 같은 주소 공간을 쓴다.');
    add('공부/운영체제', '페이지 교체 알고리즘 LRU', '가장 오래 안 쓴 것', 'LRU는 최근 사용 시각으로 고른다.');
    add('생활·기기/맥 관리', '외장 SSD를 APFS 이미지로 쓰기', 'sparsebundle', 'hdiutil로 만들고 /Volumes에 붙인다.');
    add('생활·기기/맥 관리', '디스크 정리 순서', '캐시 → 빌드 산출물', 'build/와 DerivedData를 먼저 지운다.');

    // 예전 방식(구역 없음) 노트: [폴더 정리] 제안 대상
    add(
      '세컨드브레인 개발',
      '릴리스 빌드 서명 오류 해결',
      'codesign 재서명',
      '서명 오류가 났다.\n\n원인은 entitlements 누락.',
      isLegacy: true,
      sources: [s3],
      attachments: [?imagePath],
    );
    add('세컨드브레인 개발', '릴리스 빌드 순서', 'tool/build_brain.sh 먼저', 'brain CLI를 먼저 만들고 앱을 빌드한다.', isLegacy: true);
    add('결제', '결제 웹훅 재시도 규칙', '세 번까지 재시도', '1분·5분·30분 간격으로 세 번까지 재시도하고 그 뒤는 사람이 본다.', isLegacy: true);
    add('결제', '토스 결제 테스트 키로 먼저 확인', '실제 키 금지', '테스트 키로 먼저 확인한다.', isLegacy: true);
    add('맥 관리', '홈브루 정리 명령', 'brew cleanup', 'brew cleanup --prune=all', isLegacy: true);

    // 정리 대기 초안 (비슷한 정리된 노트가 있는 것)
    add('결제', '결제 웹훅 재시도 간격 정리', '1분 5분 30분', '웹훅 재시도는 1분·5분·30분 간격으로 세 번까지, 그 뒤는 사람이 본다.', draft: true, isLegacy: true, sources: [s3]);
    add(
      '개발 지식/Flutter',
      'Riverpod 오버라이드 시험 패턴',
      'Notifier 하위 클래스',
      '시험에서 Notifier를 하위 클래스로 오버라이드한다. overrideWith로 바꾼다.',
      draft: true,
      sources: [s3],
    );
    add('개발 지식/SQLite', 'FTS5 한국어 검색 메모', 'trigram 3글자', 'FTS5 trigram 토크나이저는 한국어 3글자부터 검색된다.', draft: true, sources: [s1]);
  }

  /// 적용 중 규칙 [active]개 (비슷한 쌍 포함) + 승인 대기 2개.
  void fillLessons({int active = 32}) {
    final store = LessonStore(vault, index);
    final rules = [
      ('커밋하거나 push할 때', '사용자에게 먼저 허락을 받는다', '허락 없이 커밋해 되돌린 적이 있음'),
      ('push하기 전에', '사용자 허락을 받는다', '보호 브랜치에 올릴 뻔함'),
      ('결제 코드를 수정할 때', '테스트 키로 먼저 확인한다', '실제 키로 시험해 결제가 나간 적이 있음'),
      ('결제 모듈을 고칠 때', '테스트 키로 먼저 확인한다', '실 결제 사고'),
      ('교수님께 메일을 쓸 때', '회사식으로 쓰고 "김민상 올림"으로 끝낸다', '격식'),
      ('보고를 쓸 때', '한국어로 쓰고 코드·경로만 원문으로 둔다', '사용자 요청'),
      ('설계가 바뀔 때', '설계서만 고치고 기획안은 다시 만들지 않는다', '제출 완료'),
      ('스크린샷이 필요할 때', '요청이 있을 때만 보낸다', '사용자 요청'),
      ('선택지를 물을 때', '예를 넣고 지금→바꾸면 순서로 쓴다', '이해하기 쉽게'),
      ('화면 기능을 만들 때', '오류 처리·진행 표시·실데이터 시험을 같이 한다', '기본기'),
    ];
    var n = 0;
    for (final (t, a, r) in rules) {
      if (n >= active) break;
      store.add(trigger: t, action: a, reason: r, status: LessonStatus.active, diff: n == 2 ? '- 실제 키로 결제 시험\n+ 테스트 키로 먼저 확인' : '');
      n++;
    }
    const more = [
      ('노트 1만 개 시험을 할 때', '빌드 모드를 정식(release)으로 잰다'),
      ('SQLite 색인을 열 때', 'busy_timeout을 5초로 둔다'),
      ('isolate에 일을 넘길 때', '최상위 함수와 문자열만 넘긴다'),
      ('외장 디스크 폴더를 쓸 때', '폴더를 만들지 말고 먼저 있는지 본다'),
      ('Supabase 함수를 고칠 때', '요금제 판단을 서버에 둔다'),
      ('API 키가 필요할 때', 'Edge Function 환경변수에만 둔다'),
      ('주간 보고를 만들 때', 'make.sh로 Word와 PDF를 함께 만든다'),
      ('오픈소스를 참고했을 때', '출처와 라이선스를 문서에 남긴다'),
      ('설정 파일을 시험할 때', 'BRAIN_CONFIG로 따로 된 파일을 쓴다'),
      ('그래프 배치를 바꿀 때', '저장된 위치를 먼저 쓰고 꼬이면 다시 배치한다'),
      ('Riverpod provider를 시험할 때', 'overrideWith로 하위 클래스를 넣는다'),
      ('파일을 지울 때', '휴지통(_meta/trash)으로 옮긴다'),
      ('노트 제목을 바꿀 때', '[[링크]]를 함께 고친다'),
      ('AI가 노트를 고쳤을 때', '정리 보드에 보이고 되돌릴 수 있게 한다'),
      ('웹 홍보 페이지를 고칠 때', '앱 기능을 웹에서 돌리지 않는다'),
      ('임베딩을 쓰자는 제안이 나올 때', '2단계 검토로 미룬다'),
      ('화면 배율을 바꿀 때', '⌘0으로 원래대로 돌아오게 한다'),
      ('다이얼로그에 긴 입력이 있을 때', '바깥 클릭으로 닫히지 않게 한다'),
      ('자동 정리를 켤 때', '하루 비용 상한을 먼저 묻는다'),
      ('깃 원격이 붙은 폴더일 때', '연동 메뉴에 경고 점을 띄운다'),
      ('타임라인을 그릴 때', '변경 기록의 첫 시각을 만든 날로 쓴다'),
      ('백업을 만들 때', 'ditto로 폴더째 압축한다'),
    ];
    for (final (t, a) in more) {
      if (n >= active) break;
      store.add(trigger: t, action: a, reason: '지난 교정', status: LessonStatus.active);
      n++;
    }
    store.add(trigger: '그래프 이름표를 바꿀 때', action: '긴 제목을 자르지 않고 줄을 바꾼다', reason: '말줄임으로 구분이 안 됨', status: LessonStatus.pending);
    store.add(trigger: '폴더를 옮길 때', action: '되돌리기 묶음 하나로 실행한다', reason: '중간 실패 때 되돌리기', status: LessonStatus.pending);
  }

  List<NoteLink> links() => index.links(dismissed: DismissedLinks(vault).load());

  List<AiEdit> aiEdits() => [
    AiEdit(
      noteId: ids['database is locked 피하기 (busy_timeout)']!,
      title: 'database is locked 피하기 (busy_timeout)',
      batches: const ['b_20261113-140500-a1b2', 'b_20261113-141000-c3d4'],
      firstAt: DateTime(2026, 11, 13, 14, 5),
      lastAt: DateTime(2026, 11, 13, 14, 10),
      sessions: const {'7d1c2b3a-1111-4222-8333-444455556666'},
      canRevert: true,
    ),
    AiEdit(
      noteId: ids['macOS 샌드박스에서 파일 접근 권한']!,
      title: 'macOS 샌드박스에서 파일 접근 권한',
      batches: const ['b_20261112-201000-e5f6'],
      firstAt: DateTime(2026, 11, 12, 20, 10),
      lastAt: DateTime(2026, 11, 12, 20, 10),
      sessions: const {'a91f02cc-2222-4333-8444-555566667777'},
      canRevert: false,
    ),
  ];

  List<DecisionPair> decisionPairs() => [
    DecisionPair(
      newId: ids['구역/주제 2단 폴더 구조 (5.1)']!,
      oldId: ids['릴리스 빌드 순서']!,
      newTitle: '구역/주제 2단 폴더 구조 (5.1)',
      oldTitle: '릴리스 빌드 순서',
      topic: '세컨드브레인',
      shared: 3,
    ),
  ];

  /// 앱과 같은 provider를 시험 지식 폴더로 바꾼다. 백그라운드 계산(isolate)은 화면 스레드에서 미리 계산한 값으로.
  List overrides({
    AppConfig config = const AppConfig(isFirstRunDone: true, panelWidth: 380),
    NeuralLayout? neural,
    List<IndexedDoc>? notes,
    List<NoteLink>? links,
    SystemCheck? systemCheck,
  }) {
    final allNotes = notes ?? index.notes();
    final allLinks = links ?? this.links();
    return [
      vaultProvider.overrideWithValue(vault),
      searchIndexProvider.overrideWithValue(index),
      appConfigProvider.overrideWith(() => MemoryConfig(config)),
      vaultRevisionProvider.overrideWith(StillRevision.new),
      notesProvider.overrideWithValue(allNotes),
      linksProvider.overrideWithValue(allLinks),
      lintIssuesProvider.overrideWith((ref) async => Linter(vault, index).run()),
      draftSimilarProvider.overrideWith((ref) async => NoteStore(vault, index).similarForDrafts()),
      aiEditsProvider.overrideWith((ref) async => aiEdits()),
      decisionPairsProvider.overrideWith((ref) => decisionPairs()),
      decisionCheckProvider.overrideWith(() => StillDecisionCheck(DecisionCheckState(lastRunAt: DateTime(2026, 11, 13, 9)))),
      autoTidyProvider.overrideWith(StillAutoTidy.new),
      claudeCodeStatusProvider.overrideWith(
        (ref) async =>
            const ClaudeCodeStatus(executable: '/opt/homebrew/bin/claude', version: '2.1.40', isInstalled: true, isEnabled: true),
      ),
      systemCheckProvider.overrideWith((ref) => systemCheck == null ? Completer<SystemCheck>().future : Future.value(systemCheck)),
      graphLayoutProvider.overrideWith((ref) async {
        final nodes = [
          for (final d in allNotes)
            if (!d.isMerged) GraphNode(d.id, d.topicPath),
        ];
        final edges = [for (final l in allLinks) GraphEdge(l.fromId, l.toId, weight: l.isSuggested ? 0.25 : 1)];
        return layoutGraph(nodes, edges, stored: const {}, base: null).positions;
      }),
      if (neural != null) neuralLayoutProvider.overrideWith((ref) async => neural),
    ];
  }
}

/// 노트 [count]개 합성 폴더의 신경망 배치와 노트 목록 (그림만, 파일 없음).
({NeuralLayout layout, List<IndexedDoc> notes, List<NoteLink> links}) syntheticVault(int count, {int seed = 5}) {
  const topicNames = [
    '프로젝트/세컨드브레인',
    '프로젝트/졸업작품',
    '개발 지식/Flutter',
    '개발 지식/SQLite',
    '개발 지식/Git',
    '개발 지식/Dart',
    '조사·참고/오픈소스',
    '조사·참고/논문',
    '공부/운영체제',
    '공부/네트워크',
    '공부/자료구조',
    '생활·기기/맥 관리',
    '생활·기기/여행',
  ];
  const words = ['설정', '오류 해결', '결정', '정리', '시험', '구조', '순서', '규칙', '비교', '메모', '측정', '배포'];
  final data = syntheticNeural(count, inputs: 60, topics: topicNames.length, seed: seed);
  final rnd = Random(seed);
  final specs = [
    for (final n in data.notes)
      () {
        final t = int.parse(n.topic.substring(2));
        final topic = topicNames[t];
        final title = '${topic.split('/').last} ${words[rnd.nextInt(words.length)]} ${n.id.substring(2)}';
        return NeuralNoteSpec(id: n.id, title: title, topic: topic, isDraft: n.isDraft, sources: n.sources);
      }(),
  ];
  final inputTitles = {
    for (final s in {for (final n in specs) ...n.sources}) s: '세션 ${p.basenameWithoutExtension(s).split('-').last} 대화',
  };
  final layout = layoutNeural(specs, data.links, inputTitles: inputTitles);
  final notes = [
    for (final s in specs)
      IndexedDoc(
        id: s.id,
        path: 'wiki/${s.topic}/${s.title}.md',
        kind: 'note',
        title: s.title,
        summary: '',
        tags: '',
        status: s.isDraft ? NoteStatus.draft : NoteStatus.active,
        mtime: DateTime(2026, 11, 13),
        hash: 'h',
      ),
  ];
  final links = [for (final (a, b) in data.links) NoteLink(fromId: a, toId: b, kind: 'link')];
  return (layout: layout, notes: notes, links: links);
}

/// 앱과 같은 테마·지역 설정으로 [child]를 그린다. 대화 상자도 찍히게 앱 전체를 [shotKey]로 감싼다.
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  required Brightness brightness,
  required List overrides,
  required Widget child,
}) async {
  final container = ProviderContainer(retry: (_, _) => null, overrides: [...overrides.cast()]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: shotKey,
        child: ShadApp(
          theme: buildAppTheme(brightness),
          darkTheme: buildAppTheme(Brightness.dark),
          themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          locale: const Locale('ko', 'KR'),
          supportedLocales: const [Locale('ko', 'KR')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          debugShowCheckedModeBanner: false,
          // 앱 builder와 같은 기본 글꼴(withAppFont). 그 글꼴에 없는 글자만 시스템 대체 글꼴로
          builder: (context, child) => DefaultTextStyle.merge(style: systemTextStyle, child: withAppFont(child!)),
          home: child,
        ),
      ),
    ),
  );
  await settle(tester);
  return container;
}

/// FutureProvider가 끝나고 애니메이션이 멈출 때까지. 영원히 도는 애니메이션이 있으면 정해진 시간만 넘긴다.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  try {
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
  } on FlutterError {
    // 계속 도는 애니메이션: 그대로 찍는다
  }
}

/// 그림 파일 (가짜 빌드 화면 캡처 640×360).
Future<String> makeSamplePng(WidgetTester tester, String dir) async {
  final path = p.join(dir, 'build-error.png');
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const w = 640.0, h = 360.0;
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xff1e1e2e));
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, 28), Paint()..color = const Color(0xff313244));
    for (final (i, c) in [const Color(0xffff5f57), const Color(0xfffebc2e), const Color(0xff28c840)].indexed) {
      canvas.drawCircle(Offset(16 + i * 18.0, 14), 6, Paint()..color = c);
    }
    final rnd = Random(3);
    for (var line = 0; line < 12; line++) {
      final isError = line == 6 || line == 7;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(20, 44 + line * 24.0, 120 + rnd.nextDouble() * 440, 10), const Radius.circular(3)),
        Paint()..color = isError ? const Color(0xfff38ba8) : const Color(0xff6c7086),
      );
    }
    final image = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  return path;
}

/// [testWidgets]와 같지만, 넘침(노랑·검정 줄무늬) 같은 화면 오류로 멈추지 않고 모아 두었다가 `_errors.txt`에 적는다.
/// 오류가 나도 그림은 찍는다 (줄무늬가 그대로 보여야 사람이 볼 수 있다).
void visualTest(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, skip: visualOut == null, (tester) async {
    final errors = <String>[];
    final old = FlutterError.onError;
    FlutterError.onError = (details) {
      final where = RegExp(r'(lib/[^\s:]+\.dart:\d+:\d+)').allMatches(details.toString()).map((m) => m.group(1)).toSet();
      errors.add('${details.exceptionAsString().split('\n').first}  @ ${where.join(', ')}');
    };
    try {
      await body(tester);
    } finally {
      FlutterError.onError = old;
      if (errors.isNotEmpty) {
        final text = '## $description\n${errors.toSet().map((e) => '- $e').join('\n')}\n\n';
        // ignore: avoid_print
        print(text);
        File(p.join(visualOut!, '_errors.txt'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text, mode: FileMode.append);
      }
    }
  });
}
