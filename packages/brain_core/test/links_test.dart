import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('links_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  test('본문의 [[제목]]을 읽고 코드 안 대괄호는 뺀다', () {
    expect(
      parseWikiLinks('[[결제 웹훅]] 과 [[토스 키|키]] [[결제 웹훅#재시도]]\n`[[아님]]`\n```\n[[아님2]]\n```'),
      ['결제 웹훅', '토스 키'],
    );
  });

  test('[[제목]]·별칭·풀어 쓴 한글로 노트를 잇고, 없는 대상은 죽은 링크', () {
    final (a, _) = store.add(
      title: '결제 웹훅 재시도 규칙',
      summary: '웹훅 실패 시 3번까지 재시도',
      body: '자세한 키는 [[토스 테스트 키]]를 본다. [[없는 노트]]도 있다.',
      tags: ['결제'],
    );
    final path = p.join(vault.wikiDir, '결제', '토스 테스트 키.md');
    writeFileAtomic(path, '''---
id: n_0002
title: "토스 테스트 키"
summary: "테스트 키 위치"
aliases: ["toss key"]
---
본문 [[결제 웹훅 재시도 규칙]] 그리고 [[TOSS KEY]]
''');
    index.sync();
    final manual = index.links().where((l) => !l.isSuggested).toList();
    expect(
      manual.map((l) => '${l.fromId}->${l.toId}').toSet(),
      {'$a->n_0002', 'n_0002->$a'},
    );
    expect(index.deadLinks().map((d) => d.target), ['없는 노트']);
    expect(index.byTitle('Toss Key')?.id, 'n_0002');
  });

  test('비슷한 노트끼리 추천 연결이 생기고 관계없는 노트는 잇지 않는다', () {
    store.add(
      title: '결제 웹훅 재시도',
      summary: '웹훅 실패 시 재시도',
      body: '결제 웹훅이 실패하면 1분 5분 30분 간격으로 재시도한다. 웹훅 서명도 확인한다.',
    );
    store.add(
      title: '웹훅 서명 검증',
      summary: '결제사 웹훅 서명 확인 방법',
      body: '결제사가 보낸 웹훅은 서명 헤더로 검증한다. 실패하면 재시도를 기다린다.',
    );
    store.add(
      title: '아이폰 사진 백업',
      summary: '사진만 외장으로 옮기기',
      body: '이미지 캡처 앱으로 사진을 외장 드라이브에 복사한다.',
    );
    final suggested = index.links().where((l) => l.isSuggested).toList();
    final pairs = suggested.map((l) => ([l.fromId, l.toId]..sort()).join('-'));
    expect(pairs, contains('n_0001-n_0002'));
    expect(pairs.any((pair) => pair.contains('n_0003')), isFalse);
  });

  test('색인 버전이 낮으면 열 때 다시 색인한다', () {
    store.add(title: '가', summary: '가', body: '본문 [[나]]');
    index.db.execute('pragma user_version = 1');
    index.db.execute('delete from link_targets');
    index.close();
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    expect(index.deadLinks().single.target, '나');
  });
}
