import 'dart:io';
import 'dart:math';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 옮기기·이름 바꾸기·되돌리기 뒤에도 연결(직접·추천)과 고아 노트가 다시 만들기와 같아야 한다
/// (설계서_프롬프트이후 5.1, 11/13 실제 옮기기에서 발견: 노트 92개를 구역으로 옮기자 고아 노트 4 → 10, 다시 만들기로 4).
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late NoteStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('link_graph_');
    vault = Vault(p.join(temp.path, 'SecondBrain'))..ensure();
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    store = NoteStore(vault, index, zoned: true);
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  /// 묶음마다 드문 낱말 4개를 함께 쓰는 노트들. 묶음 하나는 노트 1개라 고아다.
  /// 홀수 번째는 머리말 없는 파일(파일 이름이 제목) — 옮길 때 머리말을 적느라 내용이 바뀐다.
  /// 짝수 번째는 번호·제목이 있는 파일 — 내용이 같아 경로만 바뀐다. 실제 지식 폴더도 둘이 섞여 있었다.
  List<String> makeVault({int groups = 8, int perGroup = 4}) {
    final random = Random(7);
    String word() => String.fromCharCodes([for (var i = 0; i < 3; i++) 0xAC00 + random.nextInt(11172)]);
    var n = 0;
    final titles = <String>[];
    for (var g = 0; g < groups; g++) {
      final shared = [for (var i = 0; i < 4; i++) word()];
      final count = g == groups - 1 ? 1 : perGroup;
      for (var k = 0; k < count; k++) {
        n++;
        final own = [for (var i = 0; i < 3; i++) word()];
        final title = '노트 $n ${own.first}';
        final link = n == 3 ? '\n[[${titles.first}]] 참고\n' : '';
        final body = '${List.filled(3, shared.join(' ')).join(' ')} ${shared.take(2 + k % 2).join(' ')} ${own.join(' ')}$link\n';
        final dir = Directory(p.join(vault.wikiDir, '옛주제${g % 3}'))..createSync(recursive: true);
        final file = File(p.join(dir.path, '$title.md'));
        if (n.isOdd) {
          file.writeAsStringSync(body);
        } else {
          file.writeAsStringSync('---\nid: n_${n.toString().padLeft(4, '0')}\ntitle: "$title"\nsummary: 요약\n---\n\n$body');
        }
        titles.add(title);
      }
    }
    index.sync();
    return [for (final d in index.notes()) d.id];
  }

  Set<String> linkSet() => {
    for (final l in index.links()) '${l.kind} ${l.fromId} → ${l.toId} ${l.score.toStringAsFixed(3)}',
  };

  /// 추천 연결 표 그대로 (방향 포함). [SearchIndex.links]는 서로 추천한 쌍을 하나로 줄여 빠진 쪽이 가려진다.
  Set<String> suggestedRows() => {
    for (final row in index.db.select(
      'select f.id as a, t.id as b, s.score as score from suggested_links s '
      'join docs f on f.rowid = s.from_rowid join docs t on t.rowid = s.to_rowid',
    ))
      '${row['a']} → ${row['b']} ${(row['score'] as num).toStringAsFixed(3)}',
  };

  Set<String> orphans() => {
    for (final i in Linter(vault, index).run())
      if (i.type == LintType.orphan) i.id,
  };

  /// 지금 색인의 연결·고아와 처음부터 다시 만든 색인의 것을 견준다.
  void expectSameAsRebuild(String reason) {
    final links = linkSet();
    final rows = suggestedRows();
    final lonely = orphans();
    index.rebuild();
    expect(suggestedRows(), rows, reason: '추천 연결 표 — $reason');
    expect(linkSet(), links, reason: '연결 — $reason');
    expect(orphans(), lonely, reason: '고아 노트 — $reason');
  }

  test('노트를 구역으로 옮긴 뒤 연결·고아 노트가 다시 만들기와 같다 (머리말을 적은 노트 포함)', () {
    final ids = makeVault();
    expect(orphans(), isNotEmpty, reason: '고아 묶음이 있는 지식 폴더');
    final before = linkSet();
    final result = store.moveMany([for (final id in ids) FolderMove(id: id, topic: '개발 지식/모음')]);
    expect(result.errors, isEmpty);
    expect(result.moved, hasLength(ids.length));
    expect(linkSet(), before, reason: '옮기기만 했으니 연결은 그대로여야 한다');
    expectSameAsRebuild('옮긴 뒤');
  });

  test('일부만 옮기거나 되돌려도 다시 만들기와 같다', () {
    final ids = makeVault();
    final result = store.moveMany([for (final id in ids.take(ids.length ~/ 2)) FolderMove(id: id, topic: '프로젝트/반쪽')], batch: 'b_half');
    expect(result.moved, hasLength(ids.length ~/ 2));
    expectSameAsRebuild('반만 옮긴 뒤');
    undoBatch(vault, 'b_half');
    index.sync();
    expectSameAsRebuild('옮기기를 되돌린 뒤');
  });

  test('update로 제목을 바꿔 파일 이름이 바뀌어도 다른 노트에서 오는 추천 연결이 남는다', () {
    makeVault();
    // 가 노트는 두 낱말을 많이 써서 나 노트를 추천하지만, 나 노트의 핵심 단어는 제 낱말이라 가 노트를 추천하지 않는다.
    // 나 노트의 줄 번호가 바뀌면 가 → 나 연결이 사라졌다 (가 노트는 다시 계산하지 않음).
    final dir = Directory(p.join(vault.wikiDir, '옛주제0'));
    File(p.join(dir.path, '가 노트.md')).writeAsStringSync(
      '---\nid: n_0101\ntitle: "가 노트"\nsummary: 요약\n---\n\n탁란제 탁란제 탁란제 휘몰이 휘몰이 휘몰이 가노트\n',
    );
    File(p.join(dir.path, '나 노트.md')).writeAsStringSync(
      '---\nid: n_0102\ntitle: "나 노트"\nsummary: 요약\n---\n\n탁란제 휘몰이 '
      '${[for (final w in ['곰팡잎', '뒷골목', '솔방울', '징검돌', '푸새김']) '$w $w $w'].join(' ')}\n',
    );
    index.sync();
    bool linked() => index.links().any((l) => l.isSuggested && {l.fromId, l.toId}.containsAll(['n_0101', 'n_0102']));
    expect(linked(), isTrue);
    final (_, note, hash) = store.read('n_0102')!;
    store.update('n_0102', expectHash: hash, title: '이름 바꾼 노트', summary: note.summary, body: note.body);
    expect(index.byId('n_0102')!.path, endsWith('이름 바꾼 노트.md'));
    expect(linked(), isTrue, reason: '가 노트에서 오는 추천 연결이 남아야 한다');
    expectSameAsRebuild('이름을 바꾼 뒤');
  });

  test('노트를 지우면 그 노트를 가리키던 노트는 다음 후보로 추천을 다시 고른다', () {
    // 묶음 하나에 노트 8개: 노트마다 후보가 7개라 5개만 추천하고, 지우면 6번째가 들어온다
    makeVault(groups: 3, perGroup: 8);
    // 추천을 가장 많이 받는 노트를 지운다
    final incoming = <String, int>{};
    for (final row in suggestedRows()) {
      incoming.update(row.split(' ')[2], (n) => n + 1, ifAbsent: () => 1);
    }
    final target = (incoming.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    expect(incoming[target], greaterThan(1));
    store.delete(target);
    expectSameAsRebuild('지운 뒤');
  });

  test('파일 이름만 바꾼 머리말 없는 노트(번호가 경로로 정해짐)도 연결이 다시 만들기와 같다', () {
    makeVault();
    // 다른 노트가 추천하는 머리말 없는 노트
    final pointed = {for (final row in suggestedRows()) row.split(' ')[2]};
    final bare = index.notes().firstWhere((d) => d.id.startsWith('f_') && pointed.contains(d.id));
    final file = File(p.join(vault.root, bare.path));
    file.renameSync(p.join(file.parent.path, '새 이름.md'));
    index.sync();
    expectSameAsRebuild('바깥에서 이름을 바꾼 뒤');
  });
}
