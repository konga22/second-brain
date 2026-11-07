import 'dart:isolate';

import 'package:brain_core/brain_core.dart';

// 노트가 많을 때 화면을 멈추게 하는 계산을 백그라운드(isolate)에서 한다 (11/07 노트 1만 개 측정:
// 점검 2.1초, 노트 속 할 일 후보 1.1초를 화면 스레드에서 돌려 그동안 앱이 멈췄다).
//
// 최상위 함수로만 둔다: 클래스 메서드 안 클로저를 Isolate.run에 넘기면 보낼 수 없는 객체까지
// 붙잡혀 실패한다 (실수 노트 L-0004). 인자는 경로 문자열만 넘긴다.

/// 색인 동기화 (앱 시작 때). 노트 1만 개를 처음 색인하면 30초쯤 걸려, 화면 스레드에서 하면 그동안 앱이 멈춘다.
/// 바뀐 문서 수를 돌려준다.
Future<int> syncIndexInBackground(String vaultRoot, String indexPath) =>
    Isolate.run(() {
      final vault = Vault(vaultRoot);
      final index = SearchIndex.open(vault, path: indexPath);
      try {
        final r = index.sync();
        return r.added + r.updated + r.removed;
      } finally {
        index.close();
      }
    });

/// 노트 목록과 연결 (그래프·목록·노트 패널이 쓴다). 노트 1만 개에서 목록 54ms + 연결 100ms라
/// 지식 폴더가 바뀔 때마다 화면 스레드에서 하면 멈칫한다 (11/07 측정).
Future<({List<IndexedDoc> notes, List<NoteLink> links})> vaultViewInBackground(
  String vaultRoot,
  String indexPath,
) => Isolate.run(() {
  final vault = Vault(vaultRoot);
  final index = SearchIndex.open(vault, path: indexPath);
  try {
    return (notes: index.notes(), links: index.links(dismissed: DismissedLinks(vault).load()));
  } finally {
    index.close();
  }
});

/// 지식 폴더 점검 (죽은 링크·고아·중복·신선도·형식·길이·의심 지시문).
Future<List<LintIssue>> lintInBackground(String vaultRoot, String indexPath) =>
    Isolate.run(() {
      final vault = Vault(vaultRoot);
      final index = SearchIndex.open(vault, path: indexPath);
      try {
        return Linter(vault, index).run();
      } finally {
        index.close();
      }
    });

/// 노트 본문에서 찾은 할 일 후보와 체크 상자.
Future<({List<Todo> candidates, List<Todo> fromNotes})> noteTodosInBackground(
  String vaultRoot,
  String indexPath,
) => Isolate.run(() {
  final vault = Vault(vaultRoot);
  final index = SearchIndex.open(vault, path: indexPath);
  try {
    final store = TodoStore(vault, index);
    return (candidates: store.candidatesFromNotes(), fromNotes: store.fromNotes());
  } finally {
    index.close();
  }
});
