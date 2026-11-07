import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'background_tasks.dart';
import 'claude_code.dart';

/// 앱 전체가 쓰는 지식 폴더·색인·Claude Code 연동.
final vaultProvider = Provider<Vault>((ref) => Vault.resolve()..ensure());

final searchIndexProvider = Provider<SearchIndex>((ref) {
  final index = SearchIndex.open(ref.watch(vaultProvider));
  ref.onDispose(index.close);
  return index;
});

final noteStoreProvider = Provider<NoteStore>(
  (ref) => NoteStore(ref.watch(vaultProvider), ref.watch(searchIndexProvider)),
);

final lessonStoreProvider = Provider<LessonStore>(
  // 앱은 폴더 감시·시작 동기화로 색인을 맞추므로 읽을 때마다 다시 맞추지 않는다.
  (ref) => LessonStore(
    ref.watch(vaultProvider),
    ref.watch(searchIndexProvider),
    syncOnRead: false,
  ),
);

final todoStoreProvider = Provider<TodoStore>(
  (ref) => TodoStore(ref.watch(vaultProvider), ref.watch(searchIndexProvider)),
);

final claudeCodeProvider = Provider<ClaudeCode>(
  (ref) => ClaudeCode(vault: ref.watch(vaultProvider)),
);

/// 지식 폴더가 바뀔 때마다 1씩 오르는 번호. 폴더를 감시해 사용자 AI·Obsidian이
/// 만든 파일도 반영한다 (설계서 4.2 증분 갱신). 앱 안에서 고친 뒤에는 [bumpVault]로 올린다.
final vaultRevisionProvider = NotifierProvider<VaultRevision, int>(
  VaultRevision.new,
);

class VaultRevision extends Notifier<int> {
  Timer? _debounce;

  @override
  int build() {
    final vault = ref.watch(vaultProvider);
    ref.watch(searchIndexProvider);
    // 시작 때 동기화는 백그라운드에서 한다. 처음 색인(노트 1만 개 30초)에도 화면이 멈추지 않고,
    // 그동안은 지난 색인으로 보이다가 끝나면 번호를 올려 새로 그린다 (사이드바에 "색인 중" 표시).
    Future(() async {
      ref.read(indexingProvider.notifier).set(true);
      try {
        final changed = await syncIndexInBackground(vault.root, vault.indexPath);
        if (changed > 0 && ref.mounted) state++;
      } on Object catch (e) {
        debugPrint('[색인] 시작 동기화 실패: $e');
      } finally {
        if (ref.mounted) ref.read(indexingProvider.notifier).set(false);
      }
    });
    final subscription = Directory(vault.root)
        .watch(recursive: true)
        .listen((event) {
          final rel = p.relative(event.path, from: vault.root);
          // 우리가 남기는 되돌리기 사본·휴지통·충돌 사본은 노트가 아니다.
          if (!rel.endsWith('.md') || rel.startsWith('_meta')) return;
          _debounce?.cancel();
          // 대량 가져오기 때는 이벤트를 모아서 한 번에 처리한다.
          _debounce = Timer(const Duration(milliseconds: 300), bump);
        });
    ref.onDispose(() {
      _debounce?.cancel();
      subscription.cancel();
    });
    return 0;
  }

  void bump() {
    try {
      ref.read(searchIndexProvider).sync();
    } on Object catch (e) {
      debugPrint('[색인] 갱신 실패: $e');
    }
    state++;
  }
}

/// 시작 색인이 도는 중인가 (사이드바 상태 줄에 보인다).
final indexingProvider = NotifierProvider<Indexing, bool>(Indexing.new);

class Indexing extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// 앱 안에서 노트·실수 노트·할 일을 고친 뒤 화면을 새로 고친다.
void bumpVault(WidgetRef ref) =>
    ref.read(vaultRevisionProvider.notifier).bump();

/// 노트 목록. 정리 대기가 먼저, 그다음 최근 수정 순.
final notesProvider = Provider<List<IndexedDoc>>((ref) {
  ref.watch(vaultRevisionProvider);
  return ref.watch(searchIndexProvider).notes();
});

/// 노트 사이 연결 (거절한 추천은 뺌).
final linksProvider = Provider<List<NoteLink>>((ref) {
  ref.watch(vaultRevisionProvider);
  final dismissed = DismissedLinks(ref.watch(vaultProvider)).load();
  return ref.watch(searchIndexProvider).links(dismissed: dismissed);
});

final changeHistoryProvider = Provider<List<ChangeEvent>>((ref) {
  ref.watch(vaultRevisionProvider);
  return readChangeHistory(ref.watch(vaultProvider));
});

final lessonsProvider = Provider<List<Lesson>>((ref) {
  ref.watch(vaultRevisionProvider);
  return ref.watch(lessonStoreProvider).all();
});

/// 지식 폴더 점검 결과. 노트 1만 개에서 2초쯤 걸려 백그라운드에서 계산하고, 다시 계산하는 동안은
/// 앞 결과를 그대로 보여 준다 (`.value`).
final lintIssuesProvider = FutureProvider<List<LintIssue>>((ref) {
  ref.watch(vaultRevisionProvider);
  final vault = ref.watch(vaultProvider);
  return lintInBackground(vault.root, vault.indexPath);
});

/// 할 일 화면: 할 일 목록·AI 추천(자기 파일만 읽어 가벼움).
final todoViewProvider = Provider<({List<Todo> todos, List<Todo> suggestions})>((ref) {
  ref.watch(vaultRevisionProvider);
  final store = ref.watch(todoStoreProvider);
  return (todos: store.list(), suggestions: store.suggestions());
});

/// 할 일 화면: 노트 본문을 모두 읽어 찾은 후보·체크 상자. 노트 1만 개에서 1초가 넘어 백그라운드에서 계산한다
/// (11/07 측정: 화면을 그릴 때마다 계산해 할 일 화면 이동이 가장 느렸음).
final noteTodosProvider = FutureProvider<({List<Todo> candidates, List<Todo> fromNotes})>((ref) {
  ref.watch(vaultRevisionProvider);
  final vault = ref.watch(vaultProvider);
  return noteTodosInBackground(vault.root, vault.indexPath);
});

/// 원본(raw/) 문서. 정리 보드의 첫 열.
final rawDocsProvider = Provider<List<IndexedDoc>>((ref) {
  ref.watch(vaultRevisionProvider);
  return ref.watch(searchIndexProvider).docsOf('raw');
});

/// 오른쪽 패널에 열린 노트 id.
final selectedNoteProvider = NotifierProvider<SelectedNote, String?>(
  SelectedNote.new,
);

class SelectedNote extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

/// 그래프 노드 위치. 저장된 위치로 바로 그리고, 새 노드가 있으면 isolate에서 배치한다 (설계서 5.5).
final graphLayoutProvider = FutureProvider<Map<String, Point<double>>>((
  ref,
) async {
  final notes = ref.watch(notesProvider);
  final links = ref.watch(linksProvider);
  final index = ref.watch(searchIndexProvider);
  final nodes = [
    for (final doc in notes)
      if (!doc.isMerged) GraphNode(doc.id, doc.topic),
  ];
  final edges = [
    for (final link in links)
      GraphEdge(link.fromId, link.toId, weight: link.isSuggested ? 0.25 : 1),
  ];
  final initial = index.graphPositions();
  if (nodes.every((n) => initial.containsKey(n.id))) {
    return {for (final n in nodes) n.id: initial[n.id]!};
  }
  final positions = await Isolate.run(
    () => forceLayout(nodes, edges, initial: initial),
  );
  index.saveGraphPositions(positions);
  return positions;
});
