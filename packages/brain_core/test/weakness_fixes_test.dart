import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 11/11 독립 검토에서 찾은 높음 약점의 회귀 시험 (기능검토 5절 K-18·K-19·K-20·K-21·K-26).
/// 각 시험은 고치기 전 코드에서 실제로 실패하던 상황을 그대로 만든다 (빈 통과가 아니게, L-0006).
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore notes;
  late LessonStore lessons;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('weak_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    notes = NoteStore(vault, index);
    lessons = LessonStore(vault, index);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  (String, String) addNote(String title, {String body = '본문'}) =>
      notes.add(title: title, summary: '$title 요약', body: body, topic: '시험');

  group('K-18 id가 경로가 되는 곳', () {
    test('실수 노트 id에 경로를 넣으면 거절하고 폴더 밖 파일은 그대로', () {
      final outside = File(p.join(temp.path, 'outside.md'))..writeAsStringSync('# 밖 파일\n');
      Directory(vault.lessonsDir).createSync(recursive: true);
      for (final id in ['../../outside', '../outside', 'L-0001/../../x', 'n_0001']) {
        expect(() => lessons.setStatus(id, LessonStatus.active), throwsA(isA<NoteStoreException>()), reason: id);
      }
      expect(outside.readAsStringSync(), '# 밖 파일\n');
    });

    test('되돌리기 묶음 id에 경로를 넣으면 거절', () {
      for (final id in ['../x', '/tmp/x', 'a/b', '..']) {
        expect(() => undoBatch(vault, id), throwsArgumentError, reason: id);
      }
    });

    test('manifest가 지식 폴더 밖을 가리키면 아무것도 되돌리지 않는다', () {
      final outside = File(p.join(temp.path, 'victim.txt'))..writeAsStringSync('원래 내용');
      final dir = Directory(p.join(vault.metaDir, 'undo', 'b_evil'))..createSync(recursive: true);
      Directory(p.join(dir.path, 'files')).createSync();
      File(p.join(dir.path, 'files', '0')).writeAsStringSync('공격 내용');
      File(p.join(dir.path, 'manifest.jsonl')).writeAsStringSync(
        '${jsonEncode({'path': '../victim.txt', 'existed': true, 'backup': 'files/0'})}\n',
      );
      expect(() => undoBatch(vault, 'b_evil'), throwsArgumentError);
      expect(outside.readAsStringSync(), '원래 내용');
    });
  });

  group('K-19 노트가 아닌 문서를 노트처럼 고치기', () {
    test('승인 대기 실수 노트는 write·update·지우기로 고칠 수 없다', () {
      final (id, _) = lessons.add(trigger: '배포할 때', action: '금요일엔 안 한다', reason: '장애');
      final found = notes.read(id)!;
      final hash = found.$3;
      expect(() => notes.write(id, '덮어쓰기', expectHash: hash), throwsA(isA<NoteStoreException>()));
      expect(
        () => notes.update(id, expectHash: hash, title: '새 제목', summary: '요약', body: '본문'),
        throwsA(isA<NoteStoreException>()),
      );
      expect(() => notes.delete(id), throwsA(isA<NoteStoreException>()));
      // 고치기 전에는 여기서 status가 active로 바뀌었다.
      expect(lessons.read(id)!.status, LessonStatus.pending);
    });
  });

  group('K-20 읽을 수 없는 파일', () {
    test('UTF-8이 아닌 .md 하나가 있어도 색인·저장·찾기가 계속 된다', () {
      addNote('결제 웹훅 재시도');
      final bad = File(p.join(vault.wikiDir, '시험', '옛 회의록.md'))
        ..writeAsBytesSync([0xb0, 0xe1, 0xc1, 0xa6, 0x20, 0xc8, 0xb8, 0xc0, 0xc7, 0x0a]);
      // 고치기 전에는 여기서 FileSystemException으로 멈췄다.
      final (id, _) = addNote('막힌 뒤 저장');
      expect(notes.read(id), isNotNull);
      expect(index.search('결제 웹훅'), isNotEmpty);
      expect(index.unreadable.map((e) => e.$1), contains(p.relative(bad.path, from: vault.root)));
      final issues = Linter(vault, index).run();
      expect(issues.where((i) => i.type == LintType.unreadable), hasLength(1));
    });
  });

  group('K-21 머리말(frontmatter)이 깨진 노트', () {
    late String path;
    late String original;

    setUp(() {
      final (_, rel) = addNote('로그 보관 기간');
      path = p.join(vault.root, rel);
      // 사람이 손으로 고친 흔한 모양: 값에 쌍점, 사용자 키
      original = File(path).readAsStringSync().replaceFirst(
        RegExp(r'^title: .*$', multiLine: true),
        'title: 로그: 보관 기간\nowner: minsang',
      );
      File(path).writeAsStringSync(original);
      index.sync();
    });

    test('lint --fix-safe가 고치지 않고 깨졌다고만 알린다', () {
      final issues = Linter(vault, index).run();
      expect(issues.any((i) => i.message.contains('머리말(frontmatter)을 읽지 못함')), isTrue);
      final fixed = Linter(vault, index).fixSafe();
      expect(fixed, 0);
      expect(File(path).readAsStringSync(), original, reason: '고치기 전에는 id·태그·출처·owner가 사라졌다');
    });

    test('앱 편집·brain write도 거절한다', () {
      final doc = index.notes().firstWhere((d) => d.path.endsWith('로그 보관 기간.md'));
      final hash = notes.read(doc.id)!.$3;
      expect(() => notes.write(doc.id, '새 본문', expectHash: hash), throwsA(isA<NoteStoreException>()));
      expect(() => notes.setStatus(doc.id, NoteStatus.active), throwsA(isA<NoteStoreException>()));
      expect(File(path).readAsStringSync(), original);
    });

    test('fix-safe가 고친 것은 brain undo로 되돌릴 수 있다', () {
      // 요약만 빠진 정상 노트
      final (_, rel) = addNote('요약 빠진 노트');
      final file = File(p.join(vault.root, rel));
      final before = file.readAsStringSync().replaceFirst(RegExp(r'^summary: .*$', multiLine: true), 'summary: ""');
      file.writeAsStringSync(before);
      index.sync();
      expect(Linter(vault, index).fixSafe(batch: 'b_fixtest'), 1);
      expect(file.readAsStringSync(), isNot(before));
      undoBatch(vault, 'b_fixtest');
      expect(file.readAsStringSync(), before);
    });
  });

  group('K-26 id 겹침', () {
    test('가장 큰 번호의 노트를 지워도 다음 노트가 그 번호를 받지 않는다', () {
      addNote('첫 노트');
      final (second, _) = addNote('둘째 노트');
      notes.delete(second);
      final (third, _) = addNote('전혀 다른 노트');
      expect(third, isNot(second));
      expect(third, 'n_0003');
    });

    test('제목이 _로 시작하거나 index여도 색인에 들어가고 번호가 겹치지 않는다', () {
      final (a, relA) = addNote('_layout.tsx 구조');
      final (b, relB) = addNote('index');
      final (c, _) = addNote('다음 노트');
      expect({a, b, c}, hasLength(3));
      expect(notes.read(a)!.$2.title, '_layout.tsx 구조', reason: '제목은 그대로, 파일 이름만 바뀐다');
      expect(notes.read(b), isNotNull);
      expect(p.basename(relA).startsWith('_'), isFalse);
      expect(p.basename(relB).toLowerCase(), isNot('index.md'));
    });

    test('지운 실수 노트 번호도 다시 쓰지 않는다', () {
      lessons.add(trigger: 'a 할 때', action: 'b', reason: 'c');
      final (second, _) = lessons.add(trigger: 'd 할 때', action: 'e', reason: 'f');
      File(p.join(vault.lessonsDir, '$second.md')).deleteSync();
      index.sync();
      final (third, _) = lessons.add(trigger: 'g 할 때', action: 'h', reason: 'i');
      expect(third, 'L-0003');
    });
  });

  group('K-33 이미 있던 폴더', () {
    test('사용자가 만든 index.md·_profile.md는 덮어쓰지 않고, 자동 생성 파일만 고친다', () {
      Directory(vault.root).createSync(recursive: true);
      final userIndex = File(p.join(vault.root, 'index.md'))..writeAsStringSync('# 내 Obsidian 목차\n- 직접 쓴 것\n');
      final userProfile = File(vault.profilePath)..writeAsStringSync('내 소개\n');
      addNote('첫 노트');
      expect(userIndex.readAsStringSync(), '# 내 Obsidian 목차\n- 직접 쓴 것\n');
      expect(userProfile.readAsStringSync(), '내 소개\n');
      // 주제 목차는 우리가 처음 만든 것이라 노트가 늘면 고쳐진다
      final topicIndex = File(p.join(vault.wikiDir, '시험', 'index.md'));
      expect(topicIndex.readAsStringSync(), contains('첫 노트'));
      addNote('둘째 노트');
      expect(topicIndex.readAsStringSync(), contains('둘째 노트'));
    });
  });

  group('K-32 지식 폴더가 사라졌을 때', () {
    test('동기화는 아무것도 지우지 않고 오류로 끝나며, 폴더가 돌아오면 그대로 찾는다', () async {
      final (id, _) = addNote('외장 디스크 노트');
      final moved = '${vault.root}_moved';
      Directory(vault.root).renameSync(moved);
      expect(() => index.sync(), throwsA(isA<VaultMissingException>()));
      expect(() => index.syncIfStale(fullEvery: Duration.zero), throwsA(isA<VaultMissingException>()));
      expect(index.byId(id), isNotNull, reason: '색인이 비면 안 된다');
      Directory(moved).renameSync(vault.root);
      expect(index.syncIfStale().removed, 0);
      expect(index.search('외장 디스크').map((d) => d.id), contains(id));
    });
  });

  test('K-32 깨진 색인 파일은 지우고 다시 만든다', () {
    addNote('깨진 색인 노트');
    index.close();
    final dbPath = p.join(temp.path, 'index.db');
    for (final suffix in ['-wal', '-shm']) {
      final f = File('$dbPath$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    File(dbPath).writeAsStringSync('이건 SQLite 파일이 아니다 ' * 200);
    index = SearchIndex.open(vault, path: dbPath);
    expect(index.search('깨진 색인').map((d) => d.title), contains('깨진 색인 노트'));
    notes = NoteStore(vault, index);
    lessons = LessonStore(vault, index);
  });

  group('K-36 회귀 시험 상한', () {
    test('30개가 차도 규칙은 저장되고, 시험을 지우면 다시 넣을 수 있다', () {
      for (var i = 0; i < LessonStore.maxTests; i++) {
        lessons.add(trigger: '상황 $i', action: '행동 $i', reason: '이유', question: '질문 $i', expect: '통과 $i');
      }
      expect(index.docsOf('test'), hasLength(LessonStore.maxTests));
      final (full, noTest) = lessons.add(trigger: '꽉 찬 뒤', action: '행동', reason: '이유', question: '질문', expect: '통과');
      expect(lessons.read(full), isNotNull, reason: '예전에는 규칙까지 실패했다');
      expect(noTest, isNull);
      final victim = lessons.allTests().first;
      lessons.removeTest(victim.id);
      expect(index.docsOf('test'), hasLength(LessonStore.maxTests - 1));
      expect(lessons.read(victim.lesson)!.tests, isNot(contains(victim.id)));
      final (_, again) = lessons.add(trigger: '자리 난 뒤', action: '행동', reason: '이유', question: '질문', expect: '통과');
      expect(again, isNotNull);
      expect(() => lessons.removeTest('L-0001'), throwsA(isA<NoteStoreException>()));
      expect(() => lessons.removeTest('../x'), throwsA(isA<NoteStoreException>()));
    });
  });
}
