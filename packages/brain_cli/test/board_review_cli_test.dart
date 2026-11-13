import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 정리 보드 점검의 CLI 쪽 (설계서_프롬프트이후 4.3 AI가 고친 노트).
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
}
