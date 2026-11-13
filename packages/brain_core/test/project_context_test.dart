import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 프로젝트 문맥 (설계서_프롬프트이후 5.4).
///
/// 프로젝트 폴더에서 AI를 열면 그 프로젝트의 "지금 상태"와 "다음 할 일"을 세션 시작 때 바로 알게 한다. 페이지는
/// `wiki/프로젝트/<이름>/_project.md`다 — 같은 폴더의 `index.md`는 [VaultSummary]가 만드는 자동 목차라 쓰지 않는다.
/// 경로는 머리의 `- 경로: /abs` 줄. 작업 폴더가 그 경로 아래면(가장 긴 경로) 두 절만 넣는다. AI 호출이 없다.
/// 한글 음절을 자모로 푼다 (NFD). macOS가 파일 이름에 쓰는 모양.
String nfd(String text) => String.fromCharCodes([
  for (final rune in text.runes)
    if (rune >= 0xAC00 && rune <= 0xD7A3) ...[
      0x1100 + (rune - 0xAC00) ~/ 588,
      0x1161 + (rune - 0xAC00) % 588 ~/ 28,
      if ((rune - 0xAC00) % 28 > 0) 0x11A7 + (rune - 0xAC00) % 28,
    ] else
      rune,
]);

void main() {
  late Directory temp;
  late Vault vault;
  late ProjectContext projects;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('project_context_');
    vault = Vault(p.join(temp.path, 'vault'))..ensure();
    projects = ProjectContext(vault);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  void page(String name, String text) {
    final file = File(p.join(vault.wikiDir, '프로젝트', name, '_project.md'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  String pageText(String name, List<String> paths, {String state = '', String next = ''}) => [
    '# $name',
    '',
    for (final path in paths) '- 경로: $path',
    '',
    '## 지금 상태',
    '',
    state,
    '',
    '## 다음 할 일',
    '',
    next,
    '',
  ].join('\n');

  test('작업 폴더가 프로젝트 경로 아래면 그 페이지, 밖이거나 이름만 비슷하면 null', () {
    page('쇼핑몰', pageText('쇼핑몰', ['/work/shop'], state: '결제 붙이는 중', next: '- 환불 화면'));
    expect(projects.find('/work/shop')?.name, '쇼핑몰');
    expect(projects.find('/work/shop/app/lib')?.name, '쇼핑몰');
    expect(projects.find('/work/shop/')?.name, '쇼핑몰');
    expect(projects.find('/work/shop2'), isNull); // 앞부분만 같은 다른 폴더
    expect(projects.find('/work'), isNull);
    expect(projects.find('/elsewhere'), isNull);
    expect(projects.find(''), isNull);
    expect(projects.find('상대/경로'), isNull);
  });

  test('겹친 경로는 가장 긴 경로가 이긴다, 한 페이지에 경로 여러 개, 머리말(frontmatter) path:도 읽는다', () {
    page('모노레포', pageText('모노레포', ['/work/mono']));
    page('모노레포 앱', pageText('모노레포 앱', ['/old/place/app', '/work/mono/apps/web']));
    page('옛 형식', '---\npath: /work/legacy\n---\n# 옛 형식\n\n## 지금 상태\n\n멈춤\n');
    expect(projects.find('/work/mono/packages/core')?.name, '모노레포');
    expect(projects.find('/work/mono/apps/web/src')?.name, '모노레포 앱');
    expect(projects.find('/old/place/app')?.name, '모노레포 앱');
    expect(projects.find('/work/legacy/x')?.name, '옛 형식');
  });

  test('NFD로 적힌 경로·작업 폴더도 같은 폴더로 본다 (macOS 한글 파일 이름)', () {
    page('기말', pageText('기말', [nfd('/Users/me/양윤모교수님 기말')], state: '발표 준비'));
    expect(projects.find('/Users/me/양윤모교수님 기말/docs')?.name, '기말');
    expect(projects.find(nfd('/Users/me/양윤모교수님 기말/docs'))?.name, '기말');
    expect(nfd('양윤모'), isNot('양윤모')); // 시험이 정말 NFD를 쓰는지
  });

  test('링크를 낀 경로도 같은 폴더로 본다 (/tmp → /private/tmp 모양): 적힌 경로·작업 폴더 어느 쪽이 링크여도', () {
    final real = Directory(p.join(temp.path, 'real', 'shop'))..createSync(recursive: true);
    final link = Link(p.join(temp.path, 'link'))..createSync(p.join(temp.path, 'real'));
    Directory(p.join(real.path, 'lib')).createSync();
    page('링크로 적음', pageText('링크로 적음', [p.join(link.path, 'shop')]));
    expect(projects.find(p.join(real.resolveSymbolicLinksSync(), 'lib'))?.name, '링크로 적음');
    page('링크로 적음', pageText('링크로 적음', [real.resolveSymbolicLinksSync()]));
    expect(projects.find(p.join(link.path, 'shop', 'lib'))?.name, '링크로 적음');
  });

  test('세션 줄: 두 절만, 사용자 데이터 표시와 페이지 위치, 다른 절·경로는 넣지 않는다', () {
    page(
      '쇼핑몰',
      '${pageText('쇼핑몰', ['/work/shop'], state: '결제 붙이는 중\n\n웹훅 재시도 끝남', next: '- 환불 화면\n- 배포')}'
      '\n## 메모\n\n넣지 않을 비밀 메모\n',
    );
    final lines = projects.find('/work/shop')!.sessionLines()!;
    final text = lines.join('\n');
    expect(lines.first, allOf(contains('쇼핑몰'), contains('wiki/프로젝트/쇼핑몰/_project.md'), contains('데이터')));
    expect(text, allOf(contains('지금 상태'), contains('결제 붙이는 중'), contains('웹훅 재시도 끝남')));
    expect(text, allOf(contains('다음 할 일'), contains('- 환불 화면'), contains('- 배포')));
    expect(text, isNot(contains('비밀 메모')));
    expect(text, isNot(contains('/work/shop')));
    expect(text.indexOf('지금 상태'), lessThan(text.indexOf('다음 할 일')));
  });

  test('절이 없거나 비면 그 절은 빼고, 둘 다 없으면 null (0자)', () {
    page('상태만', '# 상태만\n\n- 경로: /a\n\n## 지금 상태\n\n작업 중\n');
    page('빈 페이지', pageText('빈 페이지', ['/b']));
    page('절 없음', '# 절 없음\n\n- 경로: /c\n\n아무 절도 없는 글\n');
    final only = projects.find('/a')!.sessionLines()!.join('\n');
    expect(only, contains('작업 중'));
    expect(only, isNot(contains('다음 할 일')));
    expect(projects.find('/b')!.sessionLines(), isNull);
    expect(projects.find('/c')!.sessionLines(), isNull);
  });

  test('긴 절은 합계 1,200자 안으로 자른다 (짧은 절이 남긴 몫은 긴 절이 쓴다), 비밀값은 가린다', () {
    page('긴 절', pageText('긴 절', ['/long'], state: '가' * 3000, next: '나' * 3000));
    page('한쪽만 긺', pageText('한쪽만 긺', ['/half'], state: '짧은 상태', next: '다' * 3000));
    page('비밀', pageText('비밀', ['/secret'], state: '키 sk-ant-abcdefghijklmnop0123456789 넣음'));
    int body(List<String> lines) => lines.skip(1).where((l) => !l.trim().endsWith(':')).fold(0, (n, l) => n + l.trim().runes.length);
    final long = projects.find('/long')!.sessionLines()!;
    expect(body(long), inInclusiveRange(1100, ProjectContext.maxChars));
    expect(long.join('\n'), contains('…'));
    final half = projects.find('/half')!.sessionLines()!;
    expect(half.join('\n'), contains('짧은 상태'));
    expect(body(half), inInclusiveRange(1100, ProjectContext.maxChars));
    expect(projects.find('/secret')!.sessionLines()!.join('\n'), allOf(contains('[가림]'), isNot(contains('sk-ant-'))));
  });

  test('set: 새 페이지를 만들고, 다시 부르면 사용자가 쓴 절·글은 그대로 두고 고른 절만 바꾼다', () {
    final dir = Directory(p.join(temp.path, 'shop'))..createSync();
    final created = projects.set(name: '쇼핑몰', path: dir.path);
    expect(created, p.join(vault.wikiDir, '프로젝트', '쇼핑몰', '_project.md'));
    expect(projects.find(p.join(dir.path, 'lib'))?.name, '쇼핑몰');
    expect(projects.find(dir.path)!.sessionLines(), isNull); // 아직 두 절이 비었다

    // 사용자가 손으로 고친 페이지
    final file = File(created);
    file.writeAsStringSync(
      '${file.readAsStringSync().replaceFirst('## 지금 상태\n', '## 지금 상태\n\n손으로 쓴 상태\n')}\n## 메모\n\n손으로 쓴 메모\n',
    );
    projects.set(name: '쇼핑몰', next: '- 환불 화면\n- 배포');
    var text = file.readAsStringSync();
    expect(text, allOf(contains('손으로 쓴 상태'), contains('손으로 쓴 메모'), contains('- 환불 화면\n- 배포')));
    projects.set(name: '쇼핑몰', state: '결제 끝남');
    text = file.readAsStringSync();
    expect(text, allOf(contains('결제 끝남'), isNot(contains('손으로 쓴 상태')), contains('- 환불 화면'), contains('손으로 쓴 메모')));
    expect(text.indexOf('## 메모'), greaterThan(text.indexOf('## 다음 할 일')));

    // 같은 경로는 다시 적지 않고, 새 경로는 더한다
    final other = Directory(p.join(temp.path, 'shop-copy'))..createSync();
    projects.set(name: '쇼핑몰', path: dir.path);
    projects.set(name: '쇼핑몰', path: other.path);
    text = file.readAsStringSync();
    expect(RegExp('- 경로: ${RegExp.escape(dir.path)}\n').allMatches(text), hasLength(1));
    expect(projects.find(other.path)?.name, '쇼핑몰');
  });

  test('set: 절이 없던 페이지에는 끝에 절을 더한다', () {
    page('절 없음', '# 절 없음\n\n- 경로: /c\n\n사용자 글\n');
    projects.set(name: '절 없음', next: '할 일 하나');
    final text = File(projects.pagePath('절 없음')).readAsStringSync();
    expect(text, startsWith('# 절 없음\n\n- 경로: /c\n\n사용자 글\n'));
    expect(projects.find('/c')!.sessionLines()!.join('\n'), contains('할 일 하나'));
  });

  test('set: 이름·경로가 이상하면 거절 (빗금·..·_·빈 이름, 없는 폴더, 상대 경로), 없는 페이지에 경로 없이 쓰기도 거절', () {
    final dir = Directory(p.join(temp.path, 'ok'))..createSync();
    for (final bad in ['', 'a/b', '..', '.숨김', '_meta', '  ']) {
      expect(() => projects.set(name: bad, path: dir.path), throwsA(isA<ProjectContextException>()), reason: bad);
    }
    expect(() => projects.set(name: '없는 폴더', path: p.join(temp.path, 'none')), throwsA(isA<ProjectContextException>()));
    expect(() => projects.set(name: '상대', path: 'rel/dir'), throwsA(isA<ProjectContextException>()));
    expect(() => projects.set(name: '새 페이지', state: '상태'), throwsA(isA<ProjectContextException>()));
    expect(Directory(p.join(vault.wikiDir, '프로젝트')).existsSync() ? Directory(p.join(vault.wikiDir, '프로젝트')).listSync() : [], isEmpty);
  });

  test('자동 목차(VaultSummary)와 색인은 _project.md를 건드리지 않고, 같은 폴더의 index.md 목차는 그대로 만든다', () {
    final index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    try {
      final dir = Directory(p.join(temp.path, 'shop'))..createSync();
      projects.set(name: '쇼핑몰', path: dir.path, state: '결제 붙이는 중');
      NoteStore(vault, index, zoned: true).add(title: '결제 웹훅', summary: '재시도', body: '본문', topic: '프로젝트/쇼핑몰');
      final before = File(projects.pagePath('쇼핑몰')).readAsStringSync();
      VaultSummary(vault, index).writeAll();
      index.sync();
      expect(File(projects.pagePath('쇼핑몰')).readAsStringSync(), before);
      expect(File(p.join(vault.wikiDir, '프로젝트', '쇼핑몰', 'index.md')).readAsStringSync(), allOf(contains('(자동 생성)'), contains('결제 웹훅')));
      expect(index.notes().map((d) => d.title), ['결제 웹훅']); // 페이지는 노트가 아니다
    } finally {
      index.close();
    }
  });

  test('찾기는 wiki/프로젝트/*/만 본다: 프로젝트 200개·노트 폴더가 많아도 빠르다', () {
    for (var i = 0; i < 200; i++) {
      page('프로젝트 $i', pageText('프로젝트 $i', ['/work/p$i'], state: '상태 $i'));
      // 페이지 없는 주제 폴더(노트만 있음)도 섞는다
      Directory(p.join(vault.wikiDir, '프로젝트', '노트만 $i')).createSync(recursive: true);
    }
    final watch = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      expect(projects.find('/work/p199/src')?.name, '프로젝트 199');
    }
    watch.stop();
    // ignore: avoid_print
    print('[프로젝트 문맥] 페이지 200개에서 찾기 ${(watch.elapsedMicroseconds / 20 / 1000).toStringAsFixed(1)}ms');
    expect(watch.elapsedMilliseconds / 20, lessThan(30));
  });
}
