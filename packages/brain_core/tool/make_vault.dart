// 성능 측정용 가짜 지식 폴더 (설계서 5.8 "노트 1만 개"). 같은 씨앗이면 같은 폴더가 나온다.
//
//   dart run tool/make_vault.dart <만들 폴더> [노트 수 = 10000]
//
// 주제 40개, 본문 300~1,500자(한글 단어 + 영어 개발 용어), `[[링크]]` 0~3개. 11/07 측정 조건과 같다
// (그때 쓴 생성 스크립트는 임시 폴더에 있어 사라졌다 — 11/12 다시 만듦).
import 'dart:io';
import 'dart:math';

const _words = [
  '결제', '웹훅', '재시도', '배포', '서버', '로그', '보관', '기간', '색인', '검색', '그래프', '노트', '연결', '주제',
  '설정', '권한', '토큰', '세션', '정리', '저장', '앱', '화면', '버튼', '오류', '처리', '진행', '표시', '시험',
  '측정', '속도', '파일', '폴더', '이름', '제목', '요약', '본문', '규칙', '실수', '교정', '검증', '회귀', '사본',
  '캐시', '동기화', '백그라운드', '업데이트', '설치', '연동', '훅', '스킬', '플러그인', '명령', '출력', '입력',
  '사용자', '기기', '데이터', '보안', '비밀값', '가림', '경계', '지시', '주입', '모델', '비용', '크레딧', '요금제',
];
const _english = ['Flutter', 'Dart', 'SQLite', 'FTS5', 'Supabase', 'Claude', 'Xcode', 'Swift', 'Riverpod', 'Deno', 'API', 'CLI'];
const _endings = ['을', '를', '이', '가', '은', '는', '에서', '으로', '하고', '했다', '한다', '이다'];

void main(List<String> args) {
  final root = Directory(args.first);
  final count = args.length > 1 ? int.parse(args[1]) : 10000;
  if (root.existsSync() && root.listSync().isNotEmpty) {
    stderr.writeln('폴더가 비어 있지 않습니다: ${root.path}');
    exit(1);
  }
  final random = Random(20261112);
  final topics = [for (var i = 0; i < 40; i++) '주제${i.toString().padLeft(2, '0')}'];
  final titles = <String>[];
  String sentence() {
    final n = 4 + random.nextInt(8);
    return [
      for (var i = 0; i < n; i++)
        random.nextInt(6) == 0
            ? _english[random.nextInt(_english.length)]
            : '${_words[random.nextInt(_words.length)]}${random.nextBool() ? _endings[random.nextInt(_endings.length)] : ''}',
    ].join(' ');
  }

  for (var i = 1; i <= count; i++) {
    titles.add('${_words[random.nextInt(_words.length)]} ${_words[random.nextInt(_words.length)]} $i');
  }
  final w = Stopwatch()..start();
  for (var i = 1; i <= count; i++) {
    final topic = topics[(pow(random.nextDouble(), 1.5) * topics.length).floor()];
    final target = random.nextInt(300) + 1200 * random.nextDouble();
    final body = StringBuffer();
    while (body.length < target.clamp(300, 1500)) {
      body.writeln('${sentence()}.');
    }
    final links = random.nextInt(4);
    for (var k = 0; k < links; k++) {
      body.writeln('관련: [[${titles[random.nextInt(count)]}]]');
    }
    final id = 'n_${i.toString().padLeft(5, '0')}';
    final title = titles[i - 1];
    final file = File('${root.path}/wiki/$topic/$title.md')..createSync(recursive: true);
    file.writeAsStringSync('''---
id: $id
title: "$title"
summary: "${sentence().split(' ').take(5).join(' ')}"
tags: ["$topic"]
aliases: []
source: manual
sources: []
created: 2026-11-01T10:00:00+09:00
updated: 2026-11-01T10:00:00+09:00
status: active
---

$body''');
  }
  Directory('${root.path}/_log').createSync(recursive: true);
  Directory('${root.path}/_meta').createSync(recursive: true);
  stdout.writeln('노트 $count개, 주제 ${topics.length}개 → ${root.path} (${w.elapsedMilliseconds}ms)');
}
