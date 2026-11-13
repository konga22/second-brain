import 'dart:io';
import 'dart:typed_data';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 캡처 첨부 (설계서_프롬프트이후 5.5): 사진은 `assets/<해시>.<확장자>`로 한 번만, 본문 끝에 링크.
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('assets_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  /// 머리(매직 바이트)만 진짜이고 나머지는 [seed]로 채운 사진 파일.
  String image(String name, {int size = 2048, int seed = 1}) {
    final bytes = Uint8List(size);
    for (var i = 0; i < size; i++) {
      bytes[i] = (i * 31 + seed) & 0xff;
    }
    final ext = p.extension(name).toLowerCase();
    final head = switch (ext) {
      '.png' => [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      '.jpg' || '.jpeg' => [0xff, 0xd8, 0xff, 0xe0],
      '.gif' => 'GIF89a'.codeUnits,
      '.webp' => [...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits],
      '.heic' => [0, 0, 0, 0x18, ...'ftypheic'.codeUnits],
      _ => <int>[],
    };
    bytes.setRange(0, head.length, head);
    final file = File(p.join(temp.path, 'in', name))..createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file.path;
  }

  List<File> assetFiles() {
    final dir = Directory(p.join(vault.root, 'assets'));
    return dir.existsSync() ? dir.listSync().whereType<File>().toList() : [];
  }

  String bodyOf(String id) => store.read(id)!.$2.body;

  test('사진 1장 → assets/에 1개, 본문 끝 링크가 노트 폴더에서 그 파일을 가리킨다', () {
    final png = image('스크린샷 2026-11-13 오후 3.12.45.png');
    final (id, path) = store.add(
      title: '빌드 오류 화면',
      summary: '서명 오류가 난 화면',
      body: 'Xcode 서명 오류가 났다.\n',
      topic: 'Flutter',
      attachments: [png],
    );
    final files = assetFiles();
    expect(files, hasLength(1));
    expect(p.basename(files.single.path), matches(RegExp(r'^[0-9a-f]{16}\.png$')));
    expect(files.single.readAsBytesSync(), File(png).readAsBytesSync());

    final body = bodyOf(id);
    expect(body.trim(), startsWith('Xcode 서명 오류가 났다.'));
    final link = RegExp(r'!\[([^\]]*)\]\(([^)]+)\)\s*$').firstMatch(body.trimRight());
    expect(link, isNotNull, reason: '본문 끝에 사진 링크가 있어야 한다');
    final target = p.normalize(p.join(vault.root, p.dirname(path), link!.group(2)!));
    expect(target, files.single.path);
    expect(link.group(2), startsWith('../../assets/'));
  });

  test('같은 사진을 다른 노트에 다시 붙이면 그대로 1개이고 두 노트가 같은 파일을 가리킨다', () {
    final png = image('a.png');
    final copy = File(png).copySync(p.join(temp.path, 'in', '다른 이름.PNG')).path;
    final (a, _) = store.add(title: '첫 노트', summary: '요약', body: '본문', attachments: [png]);
    final (b, _) = store.add(title: '둘째 노트', summary: '요약', body: '본문', topic: '다른 주제', attachments: [copy]);
    expect(assetFiles(), hasLength(1));
    final name = p.basename(assetFiles().single.path);
    expect(bodyOf(a), contains(name));
    expect(bodyOf(b), contains(name));
  });

  test('한 번에 여러 장(png·jpg·gif·webp·heic), 같은 사진 두 번은 링크 하나', () {
    final png = image('a.png');
    final (id, _) = store.add(
      title: '여러 장',
      summary: '요약',
      body: '본문',
      attachments: [png, image('b.jpeg', seed: 2), image('c.gif', seed: 3), image('d.webp', seed: 4), image('e.heic', seed: 5), png],
    );
    final names = assetFiles().map((f) => p.extension(f.path)).toList()..sort();
    expect(names, ['.gif', '.heic', '.jpg', '.png', '.webp'], reason: 'jpeg는 jpg로 맞춘다');
    expect(RegExp(r'!\[').allMatches(bodyOf(id)), hasLength(5));
  });

  group('거절: 노트도 사진도 남기지 않는다', () {
    void expectRejected(String path, Matcher message) {
      expect(
        () => store.add(title: '거절', summary: '요약', body: '본문', attachments: [path]),
        throwsA(isA<NoteStoreException>().having((e) => e.message, 'message', message)),
      );
      expect(assetFiles(), isEmpty);
      index.sync();
      expect(index.notes(), isEmpty);
    }

    test('사진이 아닌 확장자', () => expectRejected(image('메모.txt'), contains('사진만')));
    test('확장자만 png인 글 파일', () {
      final fake = File(p.join(temp.path, 'in', '가짜.png'))
        ..createSync(recursive: true)
        ..writeAsStringSync('이건 사진이 아니다');
      expectRejected(fake.path, contains('사진 파일이 아닙니다'));
    });
    test('없는 파일', () => expectRejected(p.join(temp.path, '없음.png'), contains('없습니다')));
    test('20MB 넘는 사진', () => expectRejected(image('큰.png', size: 20 * 1024 * 1024 + 1), contains('20MB')));
  });

  test('20MB 사진은 받는다 (실제 크기)', () {
    final big = image('큰 캡처.png', size: 20 * 1024 * 1024);
    final watch = Stopwatch()..start();
    store.add(title: '큰 사진', summary: '요약', body: '본문', attachments: [big]);
    watch.stop();
    // ignore: avoid_print
    print('20MB 첨부 저장 ${watch.elapsedMilliseconds}ms');
    expect(assetFiles().single.lengthSync(), 20 * 1024 * 1024);
    expect(Directory(p.join(vault.root, 'assets')).listSync().where((e) => e.path.contains('.tmp-')), isEmpty);
  });

  test('되돌리기: 새 사진은 노트와 함께 휴지통으로, 다른 노트가 쓰는 사진은 남긴다', () {
    final png = image('a.png');
    final jpg = image('b.jpg', seed: 9);
    store.add(title: '먼저 쓴 노트', summary: '요약', body: '본문', attachments: [png], batch: 'b_first');
    store.add(title: '나중 노트', summary: '요약', body: '본문', attachments: [png, jpg], batch: 'b_second');
    expect(assetFiles(), hasLength(2));
    // 나중 노트만 되돌리면: 새로 생긴 jpg는 치우고, 먼저 쓴 노트도 쓰는 png는 그대로.
    undoBatch(vault, 'b_second');
    final left = assetFiles().map((f) => p.extension(f.path)).toList();
    expect(left, ['.png']);
    // 먼저 쓴 노트를 되돌리면 png를 쓰는 노트가 없어 치운다 (지우지 않고 휴지통).
    undoBatch(vault, 'b_first');
    expect(assetFiles(), isEmpty);
    final trash = Directory(p.join(vault.metaDir, 'trash')).listSync(recursive: true).whereType<File>();
    expect(trash.where((f) => f.path.contains('${p.separator}assets${p.separator}')), hasLength(2));
  });

  test('되돌리기: 다른 노트가 나중에 같은 사진을 붙였으면 먼저 노트를 되돌려도 사진은 남는다', () {
    final png = image('a.png');
    store.add(title: '먼저 쓴 노트', summary: '요약', body: '본문', attachments: [png], batch: 'b_first');
    store.add(title: '나중 노트', summary: '요약', body: '본문', attachments: [png], batch: 'b_second');
    undoBatch(vault, 'b_first');
    expect(assetFiles(), hasLength(1));
  });

  test('노트를 지워도 사진은 지우지 않는다 (다른 노트가 쓸 수 있음)', () {
    final (id, _) = store.add(title: '지울 노트', summary: '요약', body: '본문', attachments: [image('a.png')]);
    store.delete(id);
    expect(assetFiles(), hasLength(1));
  });

  test('변경 기록에 붙인 사진이 남는다', () {
    final (id, _) = store.add(title: '기록', summary: '요약', body: '본문', attachments: [image('a.png')]);
    final log = Directory(vault.logDir).listSync().whereType<File>().single.readAsStringSync();
    expect(log, matches(RegExp('attach $id assets/[0-9a-f]{16}\\.png')));
  });

  test('색인·점검: 사진 링크의 경로·확장자로는 찾히지 않고, assets/의 바이너리 파일 300개를 읽지 않는다', () {
    final (id, _) = store.add(title: '캡처 노트', summary: '빌드 화면', body: '서명 오류', attachments: [image('a.png')]);
    // 사진이 많은 지식 폴더: 바이너리 300개 (이름이 .md인 바이너리도 하나)
    final dir = Directory(p.join(vault.root, 'assets'));
    for (var i = 0; i < 300; i++) {
      File(p.join(dir.path, '${i.toRadixString(16).padLeft(16, '0')}.png')).writeAsBytesSync(List.filled(4096, i & 0xff));
    }
    File(p.join(dir.path, 'broken.md')).writeAsBytesSync([0xff, 0xfe, 0x00, 0x80, 0xc3]);
    index.rebuild();
    expect(index.unreadable, isEmpty, reason: 'assets/는 색인 대상이 아니다');
    expect(index.notes().map((d) => d.id), [id]);
    expect(index.search('png'), isEmpty, reason: '사진 링크의 확장자로 노트가 걸리면 안 된다');
    expect(index.search('assets'), isEmpty);
    expect(index.search('서명 오류').map((d) => d.id), [id]);
    final issues = Linter(vault, index).run();
    expect(issues.where((i) => i.type == LintType.unreadable || i.type == LintType.deadLink), isEmpty);
  });
}
