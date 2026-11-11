import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:secondbrain/core/brain_providers.dart';

/// 지식 폴더 번호(vaultRevisionProvider)가 바뀐 만큼만 오르는지 (11/11 검토 O-6).
///
/// 번호가 오를 때마다 점검·할 일 후보·목록·그래프가 다시 계산된다(노트 1만 개에서 점검만 약 2초).
/// 예전에는 앱 안에서 노트를 한 번 저장하면 [bumpVault]로 한 번, 폴더 감시가 방금 쓴 노트·자동 목차·
/// 변경 기록을 보고 한 번 더 올라 모든 계산이 두 번 돌았다.
void main() {
  late Directory tmp;
  late ProviderContainer container;
  late List<int> revisions;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('brain_revision_');
    final vault = Vault(p.join(tmp.path, 'vault'))..ensure();
    // 노트 하나를 미리 만들고 색인해 둔다.
    // 앱의 백그라운드 동기화는 vault.indexPath(캐시 폴더)를 쓰므로 같은 곳을 쓴다. 지울 때 함께 지운다.
    final setupIndex = SearchIndex.open(vault);
    NoteStore(
      vault,
      setupIndex,
    ).add(title: '웹훅 재시도', summary: '재시도 규칙', body: '세 번까지 재시도한다.');
    setupIndex.close();
    container = ProviderContainer(
      overrides: [vaultProvider.overrideWithValue(vault)],
    );
    revisions = [];
    container.listen(
      vaultRevisionProvider,
      (_, next) => revisions.add(next),
      fireImmediately: true,
    );
    // 시작 동기화와 폴더 감시가 자리 잡을 때까지
    await Future<void>.delayed(const Duration(seconds: 2));
    revisions.clear();
  });

  tearDown(() {
    final cache = Directory(p.dirname(container.read(vaultProvider).indexPath));
    container.dispose();
    tmp.deleteSync(recursive: true);
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  test('앱 안에서 노트를 저장하면 번호가 한 번만 오른다', () async {
    final store = container.read(noteStoreProvider);
    final id = container.read(searchIndexProvider).notes().single.id;
    final (_, note, hash) = store.read(id)!;
    store.update(
      id,
      expectHash: hash,
      title: note.title,
      summary: note.summary,
      body: '${note.body}\n네 번째는 사람이 본다.\n',
      tags: note.tags,
      aliases: note.aliases,
    );
    container.read(vaultRevisionProvider.notifier).bump();
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(revisions, hasLength(1), reason: '번호 변화: $revisions');
  });

  test('앱 밖(CLI·편집기)에서 노트가 생기면 번호가 오른다', () async {
    final vault = container.read(vaultProvider);
    File(p.join(vault.wikiDir, '배포', '롤백 순서.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '---\nid: n_0100\ntitle: "롤백 순서"\nsummary: "롤백 순서"\n---\n\n이전 버전으로 되돌린다.\n',
      );
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(revisions, isNotEmpty);
    expect(container.read(searchIndexProvider).byId('n_0100'), isNotNull);
  });

  test('CLI가 이미 색인을 맞춘 새 노트도 번호가 오른다 (brain add)', () async {
    final vault = container.read(vaultProvider);
    // 다른 프로세스의 brain add처럼 따로 연 색인으로 저장한다 → 앱의 백그라운드 확인은 "바뀐 것 0"
    final cli = SearchIndex.open(vault);
    NoteStore(
      vault,
      cli,
    ).add(title: '롤백 순서', summary: '되돌리는 순서', body: '이전 버전으로 되돌린다.');
    cli.close();
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(revisions, isNotEmpty);
  });
}
