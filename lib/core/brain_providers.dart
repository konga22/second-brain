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
          // 대량 가져오기 때는 이벤트를 모아서 한 번에 처리한다. 색인 확인은 백그라운드에서 하고
          // 실제로 바뀐 게 있을 때만 번호를 올린다 (노트 1만 개에서 화면 스레드 140ms 멈춤을 없앰).
          _debounce = Timer(const Duration(milliseconds: 300), _syncInBackground);
        });
    ref.onDispose(() {
      _debounce?.cancel();
      subscription.cancel();
    });
    return 0;
  }

  /// 앱 안에서 고친 뒤 부른다. 노트·실수 노트 저장(NoteStore·LessonStore)은 이미 색인을 맞췄으므로
  /// 바로 번호를 올리고, 앱 밖에서 바뀐 것(자동 정리가 만든 파일 등)은 백그라운드 확인으로 따라잡는다.
  void bump() {
    state++;
    _syncInBackground();
  }

  var _syncing = false;
  var _again = false;

  /// 색인 확인을 백그라운드(isolate)에서 하고, 바뀐 게 있으면 번호를 올린다. 도는 중에 또 불리면 끝난 뒤 한 번 더.
  Future<void> _syncInBackground() async {
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    try {
      final vault = ref.read(vaultProvider);
      final changed = await syncIndexInBackground(vault.root, vault.indexPath);
      if (changed > 0 && ref.mounted) state++;
    } on Object catch (e) {
      debugPrint('[색인] 갱신 실패: $e');
    } finally {
      _syncing = false;
      if (_again && ref.mounted) {
        _again = false;
        unawaited(_syncInBackground());
      }
    }
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

/// 노트 목록과 연결. 처음 한 번은 바로 읽고, 그 뒤 지식 폴더가 바뀌면 백그라운드에서 다시 읽어
/// 끝나면 한 번에 바꾼다 (그동안은 앞 값을 보여 준다). 노트 1만 개에서 바뀔 때마다 154ms 멈추던 것을 없앰.
final vaultViewProvider =
    NotifierProvider<VaultView, ({List<IndexedDoc> notes, List<NoteLink> links})>(VaultView.new);

class VaultView extends Notifier<({List<IndexedDoc> notes, List<NoteLink> links})> {
  var _generation = 0;

  @override
  ({List<IndexedDoc> notes, List<NoteLink> links}) build() {
    final vault = ref.watch(vaultProvider);
    final index = ref.watch(searchIndexProvider);
    ref.listen(vaultRevisionProvider, (_, _) => _refresh());
    return (notes: index.notes(), links: index.links(dismissed: DismissedLinks(vault).load()));
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    final vault = ref.read(vaultProvider);
    try {
      final next = await vaultViewInBackground(vault.root, vault.indexPath);
      // 늦게 끝난 앞 요청이 새 결과를 덮지 않게
      if (generation == _generation && ref.mounted) state = next;
    } on Object catch (e) {
      debugPrint('[목록] 다시 읽기 실패: $e');
    }
  }
}

/// 노트 목록. 정리 대기가 먼저, 그다음 최근 수정 순.
final notesProvider = Provider<List<IndexedDoc>>(
  (ref) => ref.watch(vaultViewProvider.select((v) => v.notes)),
);

/// 노트 사이 연결 (거절한 추천은 뺌).
final linksProvider = Provider<List<NoteLink>>(
  (ref) => ref.watch(vaultViewProvider.select((v) => v.links)),
);

final changeHistoryProvider = Provider<List<ChangeEvent>>((ref) {
  ref.watch(vaultRevisionProvider);
  return readChangeHistory(ref.watch(vaultProvider));
});

/// 처음 생긴 시각 (설계서 3.0 날짜 표시): 노트·실수 노트 id → add·lesson-add 시각, 할 일은 `todo:<내용>` → 추가 시각.
/// 변경 기록(최근 3달)에서 가장 이른 것. 없으면 화면이 파일 시각을 쓴다.
final firstSeenProvider = Provider<Map<String, DateTime>>((ref) {
  final out = <String, DateTime>{};
  void keep(String key, DateTime at) {
    final old = out[key];
    if (old == null || at.isBefore(old)) out[key] = at;
  }

  for (final e in ref.watch(changeHistoryProvider)) {
    switch (e.action) {
      case 'add' || 'lesson-add' || 'import':
        keep(e.detail.split(' ').first, e.at);
      case 'todo-add' || 'todo-accept' || 'todo-suggest':
        keep('todo:${e.detail.trim()}', e.at);
    }
  }
  return out;
});

/// 실수 노트 파일 시각 (변경 기록에 lesson-add가 없을 때 만듦 대신).
final lessonsFileTimeProvider = Provider<Map<String, DateTime>>((ref) {
  ref.watch(vaultRevisionProvider);
  final dir = Directory(ref.watch(vaultProvider).lessonsDir);
  if (!dir.existsSync()) return const {};
  return {
    for (final f in dir.listSync().whereType<File>())
      if (f.path.endsWith('.md')) p.basenameWithoutExtension(f.path): f.statSync().modified,
  };
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

  void select(String? id) {
    state = id;
    if (id != null) ref.read(openedNotesProvider.notifier).add(id);
  }
}

/// 이번 실행에서 한 번이라도 연 노트 (설계서 3.0 E2: 연 초안만 한꺼번에 확인).
final openedNotesProvider = NotifierProvider<OpenedNotes, Set<String>>(OpenedNotes.new);

class OpenedNotes extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void add(String id) {
    if (!state.contains(id)) state = {...state, id};
  }
}

/// 충돌 사본 수 (설계서 3.0 E4). 앱·CLI·AI가 같은 노트를 동시에 고치면 `_meta/conflicts/`에 사본이 생긴다.
final conflictCountProvider = Provider<int>((ref) {
  ref.watch(vaultRevisionProvider);
  final dir = Directory(p.join(ref.read(vaultProvider).metaDir, 'conflicts'));
  if (!dir.existsSync()) return 0;
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => !p.basename(f.path).startsWith('.'))
      .length;
});

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
