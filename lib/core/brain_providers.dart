import 'dart:async';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

final claudeCodeProvider = Provider<ClaudeCode>(
  (ref) => ClaudeCode(vault: ref.watch(vaultProvider)),
);

/// 노트 목록. 지식 폴더를 감시해 사용자 AI·Obsidian이 만든 파일도 바로 반영한다 (설계서 4.2 증분 갱신).
final notesProvider = StreamProvider<List<IndexedDoc>>((ref) {
  final vault = ref.watch(vaultProvider);
  final index = ref.watch(searchIndexProvider);
  final controller = StreamController<List<IndexedDoc>>();
  Timer? debounce;

  void refresh() {
    index.sync();
    if (!controller.isClosed) controller.add(index.notes());
  }

  refresh();
  final subscription = Directory(vault.root)
      .watch(recursive: true)
      .listen((event) {
        if (!event.path.endsWith('.md')) return;
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 300), refresh);
      });
  ref.onDispose(() {
    debounce?.cancel();
    subscription.cancel();
    controller.close();
  });
  return controller.stream;
});
