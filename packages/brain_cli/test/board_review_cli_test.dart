import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 정리 보드 점검의 CLI 쪽 (설계서_프롬프트이후 4.3 AI가 고친 노트, 4.4 (가) 저장 때 안내).
/// 실제 `brain`을 프로세스로 실행한다 (draft_separation_test와 같은 방식).
void main() {
  late Directory temp;
  late String exe;
  late String vaultRoot;
  late String configPath;
  late String indexDir;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('board_review_cli_');
    // sqlite3 빌드 훅 때문에 `dart compile exe`는 안 되고 `dart build cli`를 쓴다 (tool/build_brain.sh와 같음).
    final out = p.join(temp.path, 'build');
    final result = await Process.run(Platform.resolvedExecutable, ['build', 'cli', '-o', out]);
    if (result.exitCode != 0) fail('brain 빌드 실패: ${result.stderr}');
    exe = p.join(out, 'bundle', 'bin', 'brain');
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  setUp(() {
    final dir = Directory(p.join(temp.path, 'case'))..createSync();
    vaultRoot = p.join(dir.path, 'vault');
    final vault = Vault(vaultRoot)..ensure();
    indexDir = p.dirname(vault.indexPath);
    configPath = p.join(dir.path, 'config.json');
    File(configPath).writeAsStringSync(jsonEncode({'vault': vaultRoot}));
  });

  tearDown(() {
    Directory(p.join(temp.path, 'case')).deleteSync(recursive: true);
    final dir = Directory(indexDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 사람이 터미널에서 부른 것처럼 (바깥 Claude Code 세션이 물려오지 않게). [ai]면 AI 대화 안에서 부른 것처럼.
  Future<(int, String, String)> brain(List<String> args, {String? stdin, bool ai = false, Map<String, String> env = const {}}) async {
    final process = await Process.start(exe, args, environment: {
      'BRAIN_VAULT': vaultRoot,
      'BRAIN_CONFIG': configPath,
      'CLAUDE_CODE_SESSION_ID': '',
      'CLAUDECODE': ai ? '1' : '',
      'BRAIN_LEGACY': '',
      ...env,
    });
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    return (code, await out, await err);
  }

  T withStore<T>(T Function(NoteStore store, Vault vault, SearchIndex index) body) {
    final vault = Vault(vaultRoot);
    final index = SearchIndex.open(vault);
    try {
      return body(NoteStore(vault, index), vault, index);
    } finally {
      index.close();
    }
  }

  String hashOf(String id) => withStore((store, _, _) => store.read(id)!.$3);

  group('4.3 AI가 고친 노트', () {
    test('AI 대화에서 brain write로 고친 정리된 노트는 카드가 되고, [되돌리기] 뒤 본문이 고치기 전과 같다', () async {
      final (id, human) = withStore(
        (store, _, _) => (
          store.add(title: '로그인 토큰 만료 시간', summary: '액세스 15분', body: '액세스 토큰은 15분 뒤 만료된다.\n').$1,
          store.add(title: '사람이 고친 노트', summary: '요약', body: '처음 본문\n').$1,
        ),
      );
      final original = withStore((store, _, _) => store.read(id)!.$2.body);

      const session = '7d1c2b3a-1111-4222-8333-444455556666';
      final (code, _, err) = await brain(
        ['write', id, '--expect-hash', hashOf(id)],
        stdin: '액세스 토큰은 30분 뒤 만료된다.\n',
        ai: true,
        env: {'CLAUDE_CODE_SESSION_ID': session},
      );
      expect(code, 0, reason: err);
      final (code2, _, err2) = await brain(['write', human, '--expect-hash', hashOf(human)], stdin: '사람이 고침\n');
      expect(code2, 0, reason: err2);

      final log = Directory(p.join(vaultRoot, '_log')).listSync().whereType<File>().map((f) => f.readAsStringSync()).join();
      expect(log, contains('write $id wiki/미분류/로그인 토큰 만료 시간.md · AI 대화 $session'));
      expect(RegExp('write $human .*· AI').hasMatch(log), isFalse, reason: '사람이 고친 줄에는 AI 표시가 없다');

      withStore((store, vault, index) {
        final review = AiEditReview(vault, index);
        final edit = review.pending().single;
        expect(edit.noteId, id);
        expect(edit.sessions, {session});
        review.revert(edit);
        expect(store.read(id)!.$2.body, original);
        expect(review.pending(), isEmpty);
      });
    });
  });

  group('4.4 (가) 저장 때 안내', () {
    // 정리된 노트 몇 개 (점수의 드문 정도가 뜻이 있게 서로 다른 주제로)
    const seeds = [
      ('결제', '결제 웹훅 재시도 규칙', '웹훅 실패 시 3번까지 간격을 늘려 재시도한다',
          '결제 웹훅이 실패하면 1분·5분·30분 간격으로 3번까지 다시 보낸다.\n\n- 이유: 결제사 서버 일시 장애가 대부분 30분 안에 풀렸다.'),
      ('배포', '배포 요일 규칙', '배포는 화·목만, 금요일 배포 금지', '운영 배포는 화요일과 목요일에만 한다. 금요일 배포는 하지 않는다.\n'),
      ('인증', '로그인 토큰 만료 시간', '액세스 토큰 15분, 리프레시 토큰 14일', '액세스 토큰은 15분, 리프레시 토큰은 14일 뒤 만료된다.\n'),
      ('디자인', '앱 기본 글꼴', '본문은 Pretendard 14px', '앱 본문 글꼴은 Pretendard 14px, 코드 블록은 JetBrains Mono 13px.\n'),
      ('백업', '지식 폴더 백업 주기', '매일 밤 11시 zip 백업, 30일 보관', '지식 폴더를 매일 밤 11시에 zip으로 백업하고 30일 동안 보관한다.\n'),
      ('알림', '할 일 알림 시각', '할 일 알림은 평일 오전 9시', '할 일 알림은 평일 오전 9시에 한 번 보낸다. 주말에는 보내지 않는다.\n'),
      ('검색', '검색 제목 가중치', '찾기는 제목 일치에 3배 가중치', 'FTS5 bm25 순위에서 제목 열에 3배, 본문 열에 1배 가중치를 준다.\n'),
      ('빌드', 'macOS 최소 버전', '앱의 최소 macOS 버전은 13.0', 'macOS 배포 대상(deployment target)은 13.0으로 둔다.\n'),
    ];
    const changedArgs = ['add', '--title', '결제 웹훅 재시도 5번으로 변경', '--summary', '웹훅 재시도를 3번에서 5번으로 늘렸다', '--topic', '결제'];
    const changedBody = '결제 웹훅 재시도를 3번에서 5번으로 늘린다. 간격은 1분·5분·30분·2시간·6시간.\n\n- 이유: 결제사 점검이 30분을 넘긴 날 웹훅을 잃었다.\n';

    List<String> seed() => withStore(
      (store, _, _) => [for (final (topic, t, s, b) in seeds) store.add(title: t, summary: s, body: b, topic: topic).$1],
    );

    int noteCount() => withStore((_, _, index) => index.notes().length);

    test('AI 대화에서 결정을 바꾼 노트를 저장하면 한 번 멈추고 옛 노트(id·해시)와 할 일을 알린다. --new면 저장한다', () async {
      final ids = seed();
      final before = noteCount();
      final (code, out, err) = await brain(changedArgs, stdin: changedBody, ai: true);
      expect(code, 3, reason: '강하게 맞으면 저장하지 않고 멈춘다\n$out$err');
      expect(noteCount(), before, reason: '멈췄으면 저장하지 않는다');
      expect(err, contains(ids[0]));
      expect(err, contains('해시 ${hashOf(ids[0])}'));
      expect(err, contains('brain write ${ids[0]}'));
      expect(err, contains('--new'));

      final (code2, out2, err2) = await brain([...changedArgs, '--new'], stdin: changedBody, ai: true);
      expect(code2, 0, reason: err2);
      expect(out2, contains('저장함'));
      expect(noteCount(), before + 1);
    });

    test('관계만 있는 노트는 멈추지 않고 저장한다', () async {
      seed();
      final (code, out, err) = await brain(
        ['add', '--title', '결제 영수증 메일 형식', '--summary', '영수증 메일에 주문 번호·금액·카드 끝 4자리', '--topic', '결제'],
        stdin: '결제가 끝나면 영수증 메일을 보낸다. 주문 번호, 금액, 결제 수단 끝 4자리를 넣는다.\n',
        ai: true,
      );
      expect(code, 0, reason: '$out$err');
      expect(out, contains('저장함'));
    });

    test('사람이 터미널에서 부르거나 이전 방식(BRAIN_LEGACY=decisions)이면 멈추지 않는다', () async {
      seed();
      final (human, humanOut, humanErr) = await brain(changedArgs, stdin: changedBody);
      expect(human, 0, reason: humanErr);
      expect(humanOut, contains('비슷한 정리된 노트'), reason: '멈추지는 않아도 옛 노트는 알린다');
      final (legacy, legacyOut, legacyErr) = await brain(
        [...changedArgs.sublist(0, 2), '결제 웹훅 재시도 5번 (이전 방식)', ...changedArgs.sublist(3)],
        stdin: changedBody,
        ai: true,
        env: {'BRAIN_LEGACY': 'decisions'},
      );
      expect(legacy, 0, reason: legacyErr);
      expect(legacyOut, isNot(contains('비슷한 정리된 노트')));
    });
  });
}
