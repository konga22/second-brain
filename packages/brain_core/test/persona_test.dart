import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 5.2 페르소나 질문 4문항 (설계서_프롬프트이후 5.2): `me.md` 읽고 쓰기, 금지어 검사, `_profile.md`의 추측 줄 빼기.
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('persona_');
    vault = Vault(p.join(temp.path, 'SecondBrain'))..ensure();
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index, zoned: false);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  group('me.md', () {
    test('저장한 4문항을 다시 읽으면 같다', () {
      const persona = Persona(
        work: '대림대 3학년, 세컨드 브레인 앱을 혼자 만든다',
        keeps: ['프로젝트 결정·구조', '개발 지식·해결법'],
        answerStyle: Persona.styleShort,
        forbidden: ['연봉', '집 주소'],
      );
      persona.save(vault);
      final text = File(vault.mePath).readAsStringSync();
      expect(text, contains('## 지금 하는 일\n대림대 3학년'));
      expect(text, contains('- 프로젝트 결정·구조'));
      expect(Persona.load(vault), persona);
    });

    test('없으면 null, 손으로 고친 쉼표·줄 목록과 모르는 절도 읽고 지키며, 빈 값은 빈 절로 둔다', () {
      expect(Persona.load(vault), isNull);
      File(vault.mePath).writeAsStringSync('''
# 나에 대해

## 지금 하는 일
  카페 아르바이트하며 플러터 공부

## 답 방식
자세히 단계별

## 저장하면 안 되는 것
연봉, 집 주소
- 병원
가족 이야기，

## 내 메모
손으로 적은 줄
''');
      final persona = Persona.load(vault)!;
      expect(persona.work, '카페 아르바이트하며 플러터 공부');
      expect(persona.keeps, isEmpty);
      expect(persona.answerStyle, Persona.styleDetailed);
      expect(persona.forbidden, ['연봉', '집 주소', '병원', '가족 이야기']);
      persona.copyWith(work: '바꾼 일').save(vault);
      // 사용자가 손으로 더한 절은 앱에서 저장해도 지우지 않는다
      expect(File(vault.mePath).readAsStringSync(), contains('## 내 메모\n손으로 적은 줄'));
      expect(Persona.load(vault)!.work, '바꾼 일');
    });

    test('세션 시작 한 줄: 일과 답 방식만, 금지어는 넣지 않고, 둘 다 없으면 null', () {
      expect(const Persona().sessionLine, isNull);
      expect(const Persona(forbidden: ['연봉']).sessionLine, isNull);
      expect(
        const Persona(work: '앱 개발', answerStyle: Persona.styleShort, forbidden: ['연봉']).sessionLine,
        '· 사용자: 앱 개발 · 답 방식: 짧게 결론 먼저',
      );
      expect(const Persona(answerStyle: Persona.styleDetailed).sessionLine, '· 답 방식: 자세히 단계별');
      final long = Persona(work: '가' * 100).sessionLine!;
      expect(long.runes.length, lessThan(80), reason: '긴 소개는 잘라 안내를 짧게 둔다');
      expect(const Persona(work: '줄\n바꿈').sessionLine, '· 사용자: 줄 바꿈');
    });
  });

  group('금지어', () {
    test('2글자 이상만, 대소문자·자모 풀어쓰기·띄어쓰기와 상관없이 찾고, 어느 말인지 알려 준다', () {
      final terms = ForbiddenTerms(['연봉', '돈', ' ', 'Hansol', '집 주소', '건강검진']);
      expect(terms.terms, ['연봉', 'hansol', '집 주소', '건강검진']);
      expect(terms.find('올해 연봉협상 준비'), '연봉');
      expect(terms.find('HANSOL 사내 VPN'), 'Hansol');
      expect(terms.find('집주소 바뀜'), '집 주소');
      expect(terms.find('집  주소'), '집 주소');
      // macOS에서 붙여 넣은 글은 자모로 풀려(NFD) 있을 수 있다
      expect(terms.find('건강검진 결과'), '건강검진');
      expect(terms.find('돈 계산 앱'), isNull, reason: '1글자는 너무 흔해 막지 않는다');
      expect(terms.find('연구실 서버 주소'), isNull);
      expect(ForbiddenTerms(const []).find('무엇이든'), isNull);
    });
  });

  group('NoteStore가 막는다', () {
    setUp(() => const Persona(forbidden: ['연봉', 'Hansol']).save(vault));

    test('add: 제목·요약·본문·태그 어디에 있어도 저장하지 않고 파일도 남기지 않는다', () {
      for (final (title, summary, body, tags) in [
        ('연봉 메모', '요약', '본문', <String>[]),
        ('메모', '올해 연봉 정리', '본문', <String>[]),
        ('메모', '요약', '사내 HANSOL VPN 설정', <String>[]),
        ('메모', '요약', '본문', ['hansol']),
      ]) {
        expect(
          () => store.add(title: title, summary: summary, body: body, tags: tags),
          throwsA(isA<ForbiddenTermException>()),
        );
      }
      expect(index.notes(), isEmpty);
      expect(Directory(vault.wikiDir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.md')), isEmpty);
    });

    test('거절 글에 어느 말·어느 칸인지와 다시 시도하지 말라는 말이 있다', () {
      try {
        store.add(title: '이직 준비', summary: '연봉 협상', body: '본문');
        fail('막아야 한다');
      } on ForbiddenTermException catch (e) {
        expect(e.term, '연봉');
        expect(e.message, contains('"연봉"'));
        expect(e.message, contains('요약'));
        expect(e.message, contains('사용자에게 알'));
      }
    });

    test('write·update: 금지어가 들어가면 거절하고 충돌 사본도 남기지 않는다, 빼면 저장된다', () {
      final (id, _) = store.add(title: '서버 메모', summary: '요약', body: '처음');
      final (_, _, hash) = store.read(id)!;
      expect(() => store.write(id, '연봉 이야기', expectHash: hash), throwsA(isA<ForbiddenTermException>()));
      // 해시가 틀려도 금지어가 먼저: 충돌 사본(_meta/conflicts)에 금지어가 남지 않게
      expect(() => store.write(id, '연봉 이야기', expectHash: 'zzzzzz'), throwsA(isA<ForbiddenTermException>()));
      expect(Directory(p.join(vault.metaDir, 'conflicts')).existsSync(), isFalse);
      expect(
        () => store.update(id, expectHash: hash, title: '서버 메모', summary: 'Hansol 서버', body: '처음'),
        throwsA(isA<ForbiddenTermException>()),
      );
      expect(store.read(id)!.$2.body.trim(), '처음');
      store.write(id, '두 번째', expectHash: hash);
      expect(store.read(id)!.$2.body.trim(), '두 번째');
    });

    test('me.md가 없거나 금지어가 비면 그대로 저장한다', () {
      File(vault.mePath).deleteSync();
      expect(store.add(title: '연봉 메모', summary: '요약', body: '본문').$1, 'n_0001');
      const Persona(work: '일').save(vault);
      expect(store.add(title: '연봉 메모 2', summary: '요약', body: '본문').$1, 'n_0002');
    });
  });

  group('11/13 검토에서 고친 것', () {
    test('영문 금지어는 단어로만: SK는 task·risk를 막지 않고 "SK 연봉"은 막는다', () {
      final terms = ForbiddenTerms(['SK', 'AI']);
      expect(terms.find('task risk skill desk'), isNull);
      expect(terms.find('email detail main'), isNull);
      expect(terms.find('SK 다녀요'), 'SK');
      expect(terms.find('ai 모델'), 'AI');
    });

    test('"없음" 같은 답과 "--" 같은 구분선은 금지어가 아니다', () {
      final terms = ForbiddenTerms(['없음', '--', '해당 없음', '연봉']);
      expect(terms.find('문제 없음, brain add --draft'), isNull);
      expect(terms.find('연봉 이야기'), '연봉');
    });

    test('금지어 절 제목을 조금 고쳐도 검사가 꺼지지 않는다', () {
      for (final heading in ['## 저장하면 안 되는 것 (금지)', '##저장하면 안 되는 것', '## 저장하면안되는것']) {
        expect(Persona.parse('$heading\n- 연봉\n').forbidden, ['연봉'], reason: heading);
      }
    });

    test('나중에 더한 금지어가 제목에 든 옛 노트도 깨끗한 본문으로 고칠 수 있다', () {
      final (id, _) = store.add(title: '연봉 메모', summary: '요약', body: '처음');
      const Persona(forbidden: ['연봉']).save(vault);
      final (_, _, hash) = store.read(id)!;
      expect(() => store.write(id, '새 본문', expectHash: hash), returnsNormally);
      final (_, _, hash2) = store.read(id)!;
      expect(() => store.write(id, '연봉 올림', expectHash: hash2), throwsA(isA<NoteStoreException>()));
    });

    test('실수 노트도 금지어를 지킨다', () {
      const Persona(forbidden: ['연봉']).save(vault);
      expect(
        () => LessonStore(vault, index).add(trigger: '연봉 이야기할 때', action: '줄인다', reason: '규칙'),
        throwsA(isA<NoteStoreException>()),
      );
    });
  });

  test('_profile.md에는 주제 통계만: AI가 추측한 "자주 받은 교정"은 넣지 않는다', () {
    LessonStore(vault, index).add(trigger: '커밋할 때', action: '허락을 받는다', reason: '규칙', status: LessonStatus.active);
    store.add(title: '결제 웹훅', summary: '요약', body: '본문', tags: ['결제']);
    final profile = File(vault.profilePath).readAsStringSync();
    expect(profile, contains('주요 주제: 결제(1)'));
    expect(profile, isNot(contains('교정')));
    expect(profile, isNot(contains('커밋할 때')));
  });
}
