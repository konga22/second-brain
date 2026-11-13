import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 지식 폴더 구조: 고정 구역 + 주제 (설계서_프롬프트이후 5.1).
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('zones_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index, zoned: true);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  /// 예전 방식 노트를 파일로 바로 만든다 (옮기기 전 지식 폴더 흉내).
  String legacyNote(String topic, String title, {String id = '', List<String> tags = const [], String body = '본문\n', String summary = '요약'}) {
    final legacy = NoteStore(vault, index, zoned: false);
    final (newId, _) = legacy.add(title: title, summary: summary, body: body, tags: tags, topic: topic);
    return newId;
  }

  group('경로 읽기', () {
    IndexedDoc doc(String path) => IndexedDoc(
      id: 'n_1',
      path: path,
      kind: 'note',
      title: 't',
      summary: '',
      tags: '',
      status: NoteStatus.active,
      mtime: DateTime(2026),
      hash: 'h',
    );

    test('구역 안 노트: 구역·주제·주제 경로', () {
      final d = doc('wiki/개발 지식/Flutter/a.md');
      expect(d.zone, '개발 지식');
      expect(d.topic, 'Flutter');
      expect(d.topicPath, '개발 지식/Flutter');
    });

    test('예전 노트: 구역 없음, 주제는 wiki 바로 아래 폴더', () {
      final d = doc('wiki/결제/a.md');
      expect(d.zone, isNull);
      expect(d.topic, '결제');
      expect(d.topicPath, '결제');
      // 구역 이름이 아닌 폴더 아래 하위 폴더도 예전처럼 맨 위 폴더가 주제다
      expect(doc('wiki/결제/하위/a.md').topicPath, '결제');
      expect(doc('wiki/a.md').topicPath, '미분류');
    });
  });

  group('짧은 파일 이름', () {
    test('긴 제목은 구분 기호 앞까지, 20자 안, 특수문자 없이', () {
      expect(shortNoteName('SQLite 여러 프로세스 동시 열기- busy_timeout을 WAL 설정보다 먼저'), 'SQLite 여러 프로세스 동시 열기');
      expect(shortNoteName('Render 무료 배포 체크리스트 (Node·Express, render.yaml)'), 'Render 무료 배포 체크리스트');
      // 20자에서 마침 낱말이 끝나면 그 낱말을 남긴다
      expect(shortNoteName('game-ai-research-kit 스킬 패키지 레포와 설치'), 'game ai research kit');
      // 잘린 끝의 한 글자 낱말·이음 조사는 뗀다
      expect(shortNoteName('AI 기억·그래프 RAG 레포와 안 쓰는 이유'), 'AI 기억 그래프 RAG 레포');
      expect(shortNoteName('교차 검증용 보조 AI 선택과 Kiro 구독 판단'), '교차 검증용 보조 AI 선택');
      expect(shortNoteName('Isolate.run에 메서드 안 클로저를 넘기면 unsendable 오류').runes.length, lessThanOrEqualTo(20));
      for (final title in [
        'AI에게 긴 글을 쪽으로 나눠 읽히면 중간을 건너뛴다 — 도구가 읽은 범위를 세야',
        '한반도감 홈 디자인 결정- 기존 홈 다듬기 + 아래 B(카드 하나 + 탭)',
        '아주아주아주긴띄어쓰기없는제목이라서그냥잘라야하는경우입니다',
        '_숨김처럼 보이는 제목',
        'index',
        '   ',
      ]) {
        final name = shortNoteName(title);
        expect(name.runes.length, lessThanOrEqualTo(20), reason: title);
        expect(name, isNotEmpty);
        expect(RegExp(r'[^\p{L}\p{N} ]', unicode: true).hasMatch(name), isFalse, reason: name);
        expect(name.toLowerCase() == 'index', isFalse);
      }
    });
  });

  group('새 노트 저장', () {
    test('구역/주제로 저장하면 짧은 이름 파일, 긴 제목은 파일 안에 그대로', () {
      const title = 'SQLite 여러 프로세스 동시 열기- busy_timeout을 WAL 설정보다 먼저';
      final (id, path) = store.add(title: title, summary: '요약', body: '본문\n', topic: '개발 지식/SQLite');
      expect(path, 'wiki/개발 지식/SQLite/SQLite 여러 프로세스 동시 열기.md');
      expect(store.read(id)!.$2.title, title);
      expect(index.byId(id)!.topicPath, '개발 지식/SQLite');
    });

    test('모르는 구역이면 거절하고 구역 목록과 주제를 보인다', () {
      store.add(title: '플러터 노트', summary: '요약', body: '본문\n', topic: '개발 지식/Flutter');
      expect(
        () => store.add(title: 'x', summary: '요약', body: '본문\n', topic: '개발/Flutter'),
        throwsA(
          isA<UnknownZoneException>()
              .having((e) => e.message, 'message', allOf(contains('"개발"'), contains('프로젝트'), contains('생활·기기'), contains('Flutter'))),
        ),
      );
      expect(Directory(p.join(vault.wikiDir, '개발')).existsSync(), isFalse);
    });

    test('구역만 주면 그 구역의 주제 전체를 보이고 거절한다', () {
      for (var i = 0; i < 7; i++) {
        store.add(title: '노트 $i', summary: '요약', body: '본문 $i\n', topic: '개발 지식/주제$i');
      }
      expect(
        () => store.add(title: 'x', summary: '요약', body: '본문\n', topic: '개발 지식'),
        throwsA(isA<UnknownZoneException>().having((e) => e.message, 'message', allOf(contains('주제0'), contains('주제6')))),
      );
    });

    test('구역 없이 주제 이름만 주면: 그 이름의 주제가 하나뿐이면 거기로, 없으면 거절', () {
      store.add(title: 'a', summary: '요약', body: '본문 a\n', topic: '개발 지식/Flutter');
      final (_, path) = store.add(title: 'b', summary: '요약', body: '본문 b\n', topic: 'flutter');
      expect(path, startsWith('wiki/개발 지식/Flutter/'));
      expect(
        () => store.add(title: 'c', summary: '요약', body: '본문 c\n', topic: '없는주제'),
        throwsA(isA<UnknownZoneException>()),
      );
    });

    test('구역 아래 두 단계보다 깊게는 만들지 않는다', () {
      expect(
        () => store.add(title: 'c', summary: '요약', body: '본문 c\n', topic: '공부/운영체제/3주차'),
        throwsA(isA<UnknownZoneException>()),
      );
    });

    test('이전 방식(zoned: false)은 예전처럼 wiki/<주제>/<제목>.md', () {
      final legacy = NoteStore(vault, index, zoned: false);
      final (_, path) = legacy.add(title: '긴 제목 그대로 파일 이름: 예전 방식', summary: '요약', body: '본문\n', topic: '결제');
      expect(path, 'wiki/결제/긴 제목 그대로 파일 이름- 예전 방식.md');
    });

    test('구역의 주제 목록과 찾기 범위', () {
      store.add(title: '플러터 상태 관리', summary: '요약', body: '리버팟으로 상태 관리\n', topic: '개발 지식/Flutter');
      store.add(title: '한반도감 상태 관리', summary: '요약', body: '리버팟으로 상태 관리\n', topic: '프로젝트/한반도감');
      legacyNote('결제', '결제 상태 관리', body: '리버팟으로 상태 관리\n');
      Directory(p.join(vault.wikiDir, '공부', '운영체제')).createSync(recursive: true);
      expect(index.topics(), containsAll(['개발 지식/Flutter', '프로젝트/한반도감', '결제', '공부/운영체제']));
      expect(index.topics(), isNot(contains('개발 지식')));
      expect(index.zoneTopics('공부'), ['운영체제']);
      expect(index.search('상태 관리', topic: '개발 지식/Flutter').map((d) => d.title), ['플러터 상태 관리']);
      expect(index.search('상태 관리', topic: '프로젝트').map((d) => d.title), ['한반도감 상태 관리']);
      // 구역 없이 주제 이름만 줘도 그 주제에서 찾는다 (옛 스킬·사람 입력)
      expect(index.search('상태 관리', topic: 'Flutter').map((d) => d.title), ['플러터 상태 관리']);
    });

    test('자동 목차는 구역/주제 폴더마다', () {
      store.add(title: '플러터 노트', summary: '요약 하나', body: '본문\n', topic: '개발 지식/Flutter');
      final topicIndex = File(p.join(vault.wikiDir, '개발 지식', 'Flutter', 'index.md'));
      expect(topicIndex.readAsStringSync(), contains('플러터 노트'));
      expect(File(p.join(vault.root, 'index.md')).readAsStringSync(), contains('개발 지식/Flutter'));
      expect(File(vault.profilePath).readAsStringSync(), contains('개발 지식/Flutter(1)'));
    });

    test('다른 프로세스가 구역 안에 새 주제를 만들어도 빠른 동기화가 알아챈다', () {
      store.add(title: '첫 노트', summary: '요약', body: '본문\n', topic: '개발 지식/Flutter');
      // 폴더 시각을 옛날로 돌린다: 방금 만든 폴더는 1초 여유 때문에 늘 "바뀜"으로 보여 시험이 헛통과한다
      final dirs = [for (final e in Directory(vault.root).listSync(recursive: true)) if (e is Directory) e.path];
      Process.runSync('touch', ['-t', '202601010000', vault.root, ...dirs]);
      // 2초 안의 다시 확인을 건너뛰지 않게 새 연결로 본다
      final other = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
      addTearDown(other.close);
      final file = File(p.join(vault.wikiDir, '개발 지식', '새주제', '바깥 노트.md'))..createSync(recursive: true);
      file.writeAsStringSync('---\nid: n_0900\ntitle: 바깥 노트\nsummary: 밖\n---\n본문\n');
      other.syncIfStale();
      expect(other.byId('n_0900')?.topicPath, '개발 지식/새주제');
    });
  });

  group('옮기기', () {
    String image() {
      final bytes = Uint8List(64);
      bytes.setRange(0, 8, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      final file = File(p.join(temp.path, 'in', '화면.png'))..createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      return file.path;
    }

    test('한 노트: 사진 링크를 새 자리에 맞게 다시 쓰고, 번호·제목·[[링크]]는 그대로', () {
      final legacy = NoteStore(vault, index, zoned: false);
      final (a, _) = legacy.add(title: '가 노트', summary: '요약', body: '[[나 노트]] 참고\n', topic: '옛주제');
      final (b, _) = legacy.add(title: '나 노트', summary: '요약', body: '사진\n', topic: '옛주제', attachments: [image()]);
      final before = store.read(b)!.$2.body;
      expect(before, contains('](../../assets/'));
      final rel = store.move(b, '개발 지식/새주제');
      expect(rel, 'wiki/개발 지식/새주제/나 노트.md');
      final after = store.read(b)!.$2.body;
      expect(after, contains('](../../../assets/'));
      final link = RegExp(r'\]\(([^)]+)\)').firstMatch(after)!.group(1)!;
      expect(File(p.normalize(p.join(vault.root, p.dirname(rel), link))).existsSync(), isTrue);
      expect(index.deadLinks(), isEmpty);
      expect(index.links().any((l) => l.fromId == a && l.toId == b && !l.isSuggested), isTrue);
    });

    test('머리말에 번호·제목이 없는 노트(파일 이름이 제목)는 옮기기 전에 머리말에 적는다', () {
      final file = File(p.join(vault.wikiDir, '옛주제', '파일 이름이 제목인 노트.md'))..createSync(recursive: true);
      file.writeAsStringSync('본문만 있다\n');
      index.sync();
      final id = index.notes().single.id;
      final result = store.moveMany([FolderMove(id: id, topic: '개발 지식/옛주제', name: '짧은 이름')]);
      expect(result.errors, isEmpty);
      final doc = index.notes().single;
      expect(doc.id, id);
      expect(doc.title, '파일 이름이 제목인 노트');
      expect(doc.path, 'wiki/개발 지식/옛주제/짧은 이름.md');
    });

    test('여러 노트를 한 묶음으로: 진행 표시, 틀린 줄은 오류로 남기고 나머지는 옮김, 한 번에 되돌림', () {
      final ids = [for (var i = 0; i < 5; i++) legacyNote('옛주제', '옛 노트 $i 입니다만 제목이 꽤 깁니다 정말로 깁니다', body: '본문 $i\n')];
      final progress = <(int, int)>[];
      final result = store.moveMany(
        [
          for (final id in ids) FolderMove(id: id, topic: '프로젝트/새주제'),
          const FolderMove(id: 'n_9999', topic: '프로젝트/새주제'),
          FolderMove(id: ids.first, topic: '없는구역/x'),
        ],
        batch: 'b_move-test',
        onProgress: (done, total) => progress.add((done, total)),
      );
      expect(result.moved, hasLength(5));
      expect(result.errors.map((e) => e.id), ['n_9999', ids.first]);
      expect(progress.last, (7, 7));
      expect(index.notes().length, 5);
      expect(index.notes().every((d) => d.topicPath == '프로젝트/새주제'), isTrue);
      expect(index.notes().every((d) => p.basenameWithoutExtension(d.path).runes.length <= 24), isTrue);
      // 비워진 옛 주제 폴더(자동 목차만 남음)는 치운다
      expect(Directory(p.join(vault.wikiDir, '옛주제')).existsSync(), isFalse);
      // 묶음이 남긴 "바꾼 뒤" 해시가 지금 파일과 같다 → 되돌려도 남의 고침을 덮지 않는다
      expect(driftSinceBatches(vault, ['b_move-test']), isEmpty);
      final restored = undoBatch(vault, 'b_move-test');
      expect(restored, 10);
      index.sync();
      expect(index.notes().length, 5);
      expect(index.notes().every((d) => d.topicPath == '옛주제'), isTrue);
      expect({for (final d in index.notes()) d.id}, ids.toSet());
      // 되돌리면 비워진 구역/주제 폴더도 치운다 (사이드바에 0개짜리 주제로 남지 않게)
      expect(Directory(p.join(vault.wikiDir, '프로젝트')).existsSync(), isFalse);
    });

    test('옮기기 전의 되돌리기 묶음은 "경로 바뀜": 되돌리지 않는다. 옮기기를 되돌리면 다시 된다', () {
      final legacy = NoteStore(vault, index, zoned: false);
      final (id, _) = legacy.add(title: '옛 노트', summary: '요약', body: '본문\n', topic: '옛주제', batch: 'b_old');
      legacy.update(id, expectHash: store.read(id)!.$3, title: '옛 노트', summary: '요약 고침', body: '본문\n', batch: 'b_edit');
      store.moveMany([FolderMove(id: id, topic: '개발 지식/새주제')], batch: 'b_mig');
      final edit = recentBatches(vault).firstWhere((b) => b.id == 'b_edit');
      expect(edit.isPathMoved, isTrue);
      expect(() => undoBatch(vault, 'b_edit'), throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('경로 바뀜'))));
      expect(recentBatches(vault).firstWhere((b) => b.id == 'b_mig').isPathMoved, isFalse);
      undoBatch(vault, 'b_mig');
      expect(recentBatches(vault).firstWhere((b) => b.id == 'b_edit').isPathMoved, isFalse);
      undoBatch(vault, 'b_edit');
      index.sync();
      expect(index.byId(id)!.summary, '요약');
    });

    test('옮기기만 한 파일은 다시 색인하지 않고 경로만 바꾼다: 연결이 그대로', () {
      final legacy = NoteStore(vault, index, zoned: false);
      final (a, _) = legacy.add(title: '가 노트', summary: '요약', body: '[[나 노트]] 참고\n', topic: '옛주제');
      final (b, _) = legacy.add(title: '나 노트', summary: '요약', body: '본문\n', topic: '옛주제');
      final from = File(p.join(vault.root, index.byId(b)!.path));
      final to = p.join(vault.wikiDir, '개발 지식', '새주제', '나.md');
      Directory(p.dirname(to)).createSync(recursive: true);
      from.renameSync(to);
      final result = index.sync();
      expect((result.added, result.updated, result.removed), (0, 1, 0));
      expect(index.byId(b)!.path, 'wiki/개발 지식/새주제/나.md');
      expect(index.links().any((l) => l.fromId == a && l.toId == b && !l.isSuggested), isTrue);
      // 머리말에 번호가 없는 파일은 경로가 번호를 정하므로(f_) 예전처럼 지우고 다시 색인한다
      final bare = File(p.join(vault.wikiDir, '옛주제', '번호 없음.md'))..writeAsStringSync('본문만\n');
      index.sync();
      bare.renameSync(p.join(vault.wikiDir, '개발 지식', '새주제', '번호 없음.md'));
      final again = index.sync();
      expect((again.added, again.removed), (1, 1));
    });

    test('옮긴 뒤 색인에 같은 번호가 둘이거나 f_ 번호로 바뀐 노트가 없다', () {
      final ids = [for (var i = 0; i < 30; i++) legacyNote('옛주제${i % 3}', '노트 $i', body: '본문 $i\n')];
      store.moveMany([for (final id in ids) FolderMove(id: id, topic: '개발 지식/모음')]);
      final docs = index.notes();
      expect(docs.length, 30);
      expect({for (final d in docs) d.id}, ids.toSet());
    });
  });

  group('폴더 정리 제안', () {
    test('주제마다 구역을 추정하고, 프로젝트 노트 중 기술 태그 노트만 개발 지식으로', () {
      legacyNote('세컨드브레인 개발', '세컨드 브레인 앱 기술 스택', tags: ['Flutter', '결정']);
      legacyNote('세컨드브레인 개발', 'Isolate.run에 클로저를 넘기면 오류', tags: ['Flutter', 'Dart', '버그']);
      legacyNote('세컨드브레인 개발', 'Flutter macOS 통합 시험은 파일마다', tags: ['flutter', '시험']);
      legacyNote('세컨드브레인 개발', 'Supabase 키 보관', tags: ['Supabase', '보안']);
      legacyNote('세컨드브레인 개발', '그래프 꼬임 원인', tags: ['그래프', '성능']);
      legacyNote('세컨드브레인 개발', '토큰 실측', tags: ['세컨드브레인 개발', '토큰']);
      legacyNote('한반도감', '한반도감 배포 결정', tags: ['한반도감', '배포']);
      legacyNote('한반도감', '한반도감 데이터 출처', tags: ['한반도감']);
      legacyNote('한반도감', '한반도감 홈 디자인', tags: ['한반도감', '디자인']);
      legacyNote('챗봇', '챗봇 첨부 형식 시험', tags: ['챗봇']);
      legacyNote('챗봇', '카카오톡 봇 연결', tags: ['챗봇']);
      legacyNote('참고 레포', '디자인 레포', tags: ['레포']);
      legacyNote('맥 관리', '디스크 정리', tags: ['macOS']);
      legacyNote('아이폰', '사진 백업', tags: ['아이폰']);
      legacyNote('문서 작성', '보고서 양식', tags: ['보고서']);
      legacyNote('배포', '무료 한글 도메인(.kro.kr)을 Render 앱에 붙이는 법');
      legacyNote('배포', '무료 한글 도메인(.kro.kr)을 Vercel 앱에 붙이는 법');
      store.add(title: '이미 구역 안', summary: '요약', body: '본문\n', topic: '공부/운영체제');

      final plan = {for (final m in proposeFolderMoves(index)) m.title: m};
      expect(plan, isNot(contains('이미 구역 안')));
      expect(plan['세컨드 브레인 앱 기술 스택']!.topic, '프로젝트/세컨드브레인'); // 제목에 프로젝트 이름
      expect(plan['Isolate.run에 클로저를 넘기면 오류']!.topic, '개발 지식/Flutter');
      expect(plan['Isolate.run에 클로저를 넘기면 오류']!.reason, contains('Flutter'));
      expect(plan['Flutter macOS 통합 시험은 파일마다']!.topic, '개발 지식/Flutter');
      expect(plan['Supabase 키 보관']!.topic, '프로젝트/세컨드브레인'); // 같은 기술 노트가 하나뿐이면 프로젝트에 둔다
      expect(plan['그래프 꼬임 원인']!.topic, '프로젝트/세컨드브레인');
      expect(plan['토큰 실측']!.topic, '프로젝트/세컨드브레인');
      expect(plan['한반도감 배포 결정']!.topic, '프로젝트/한반도감');
      // 주제 이름이 태그·일부 제목에 있을 뿐인 일반 주제는 프로젝트가 아니다
      expect(plan['챗봇 첨부 형식 시험']!.topic, '개발 지식/챗봇');
      expect(plan['디자인 레포']!.topic, '조사·참고/참고 레포');
      expect(plan['디스크 정리']!.topic, '생활·기기/맥 관리');
      expect(plan['사진 백업']!.topic, '생활·기기/아이폰');
      expect(plan['보고서 양식']!.topic, '개발 지식/문서 작성');
      // 같은 자리에 같은 짧은 이름이면 화면에서 미리 (2)를 보인다
      expect(
        {plan['무료 한글 도메인(.kro.kr)을 Render 앱에 붙이는 법']!.name, plan['무료 한글 도메인(.kro.kr)을 Vercel 앱에 붙이는 법']!.name},
        {'무료 한글 도메인', '무료 한글 도메인 (2)'},
      );
      for (final m in plan.values) {
        expect(m.name.runes.length, lessThanOrEqualTo(24));
        expect(m.reason, isNotEmpty);
        expect(m.from, startsWith('wiki/'));
      }
    });

    test('30개 넘는 주제는 나누기 제안', () {
      for (var i = 0; i < 31; i++) {
        store.add(title: '노트 $i', summary: '요약', body: '본문 $i\n', topic: '프로젝트/큰주제');
      }
      store.add(title: '작은', summary: '요약', body: '본문\n', topic: '프로젝트/작은주제');
      expect(oversizedTopics(index), {'프로젝트/큰주제': 31});
    });
  });

  test('되돌리기 기록이 수천 줄이어도 옮기기 2,000개가 몇 초 안에 끝난다', () {
    final dir = Directory(p.join(vault.wikiDir, '옛주제'))..createSync(recursive: true);
    for (var i = 1; i <= 2000; i++) {
      File(p.join(dir.path, '노트 $i.md')).writeAsStringSync(
        '---\nid: n_${i.toString().padLeft(4, '0')}\ntitle: "노트 $i"\nsummary: 요약\n---\n본문 $i\n',
      );
    }
    index.sync();
    final watch = Stopwatch()..start();
    final result = store.moveMany([
      for (var i = 1; i <= 2000; i++) FolderMove(id: 'n_${i.toString().padLeft(4, '0')}', topic: '개발 지식/모음'),
    ]);
    watch.stop();
    expect(result.moved, hasLength(2000));
    expect(index.notes().length, 2000);
    // 되돌리기 목록을 파일마다 처음부터 다시 읽으면 길이의 제곱으로 느려진다 (11/13 측정: 매번 읽으면 약 11.5초, 기억해 두면 약 2.9초)
    expect(watch.elapsedMilliseconds, lessThan(8000));
    final manifest = Directory(p.join(vault.metaDir, 'undo')).listSync().whereType<Directory>().single;
    final lines = File(p.join(manifest.path, 'manifest.jsonl')).readAsLinesSync().where((l) => l.isNotEmpty);
    expect(lines.length, 4000);
    expect({for (final l in lines) (jsonDecode(l) as Map)['path']}.length, 4000);
  });
}
