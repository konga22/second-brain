import 'dart:isolate';
import 'dart:math';

import 'package:brain_core/brain_core.dart';

// 노트가 많을 때 화면을 멈추게 하는 계산을 백그라운드(isolate)에서 한다 (11/07 노트 1만 개 측정:
// 점검 2.1초, 노트 속 할 일 후보 1.1초를 화면 스레드에서 돌려 그동안 앱이 멈췄다).
//
// 최상위 함수로만 둔다: 클래스 메서드 안 클로저를 Isolate.run에 넘기면 보낼 수 없는 객체까지
// 붙잡혀 실패한다 (실수 노트 L-0004). 인자는 경로 문자열만 넘긴다.

/// 그래프 배치 (설계서 5.5). 새 노드만 자리를 잡을지 처음부터 다시 배치할지는 [layoutGraph]가 정한다.
/// 전체 배치는 노드 1만 개에서 13초쯤 걸린다. 넘기는 것은 노드·연결·좌표·기록 숫자뿐이다.
Future<LayoutResult> layoutGraphInBackground(
  List<GraphNode> nodes,
  List<GraphEdge> edges,
  Map<String, Point<double>> stored,
  LayoutBase? base,
) => Isolate.run(() => layoutGraph(nodes, edges, stored: stored, base: base));

/// 색인 동기화 (앱 시작 때). 노트 1만 개를 처음 색인하면 30초쯤 걸려, 화면 스레드에서 하면 그동안 앱이 멈춘다.
/// 바뀐 문서 수를 돌려준다. 색인 버전이 낮으면(스키마를 올린 첫 실행·새 폴더) 여기서 다시 만든다 —
/// 앱의 다른 곳은 모두 `rebuildIfOld: false`로 열어 그동안 옛 색인을 본다 (11/11 K-32).
Future<int> syncIndexInBackground(String vaultRoot, String indexPath) =>
    Isolate.run(() {
      final vault = Vault(vaultRoot);
      final index = SearchIndex.open(vault, path: indexPath, busyTimeout: userWriteWait);
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
  final index = SearchIndex.open(vault, path: indexPath, rebuildIfOld: false);
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
      final index = SearchIndex.open(vault, path: indexPath, rebuildIfOld: false);
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
  final index = SearchIndex.open(vault, path: indexPath, rebuildIfOld: false);
  try {
    final store = TodoStore(vault, index);
    return (candidates: store.candidatesFromNotes(), fromNotes: store.fromNotes());
  } finally {
    index.close();
  }
});

/// 앱 안 노트 저장 (편집 창 [저장]·[내 것으로 덮어쓰기]). 쓰기라 색인을 기본값으로 연다: 처음 색인 중이면
/// 다시 만들기를 기다린다(저장 뒤 확인이 색인에 기댄다, 11/12).
/// 사용자가 기다리는 쓰기·읽기(편집 창 열기·저장, 노트 패널 버튼)가 색인 잠금을 기다리는 시간.
/// 처음 색인(다시 만들기)은 한 트랜잭션이라 노트 1만 개에서 12~20초 잠금을 쥔다. 기본 5초면 그사이 [저장]이
/// "database is locked"로 실패했다 (11/12, 작업인계 0-4). 화면에는 "저장 중…"이 보인다.
const userWriteWait = Duration(minutes: 2);

/// 새 노트면 [id]가 null이다. 저장한 노트 id를 돌려준다.
///
/// 저장은 쓰기 전·후에 색인을 맞추고 자동 목차를 다시 쓴다. 노트 1만 개에서 약 235ms라 화면 스레드에서 하면
/// 그동안 앱이 멈췄다 (11/11 검토 O-5). [NoteConflictException]·[NoteStoreException]은 그대로 다시 던져진다.
Future<String> saveNoteInBackground(
  String vaultRoot,
  String indexPath, {
  required String? id,
  required String? expectHash,
  required String title,
  required String summary,
  required String body,
  required List<String> tags,
  required List<String> aliases,
  String? topic,
  String? batch,
}) => Isolate.run(() {
  final vault = Vault(vaultRoot);
  final index = SearchIndex.open(vault, path: indexPath, busyTimeout: userWriteWait);
  try {
    final store = NoteStore(vault, index);
    if (id == null) {
      final (newId, _) = store.add(
        title: title,
        summary: summary,
        body: body,
        tags: tags,
        aliases: aliases,
        topic: topic,
        batch: batch,
      );
      return newId;
    }
    store.update(
      id,
      expectHash: expectHash!,
      title: title,
      summary: summary,
      body: body,
      tags: tags,
      aliases: aliases,
      batch: batch,
    );
    return id;
  } finally {
    index.close();
  }
});

/// 고칠 노트 읽기 (편집 창을 열 때, 충돌 뒤 다시 읽을 때). 읽기 전 색인 맞추기가 1만 개에서 약 80ms다.
Future<(IndexedDoc, Note, String)?> readNoteInBackground(
  String vaultRoot,
  String indexPath,
  String id,
) => Isolate.run(() {
  final vault = Vault(vaultRoot);
  final index = SearchIndex.open(vault, path: indexPath, busyTimeout: userWriteWait);
  try {
    return NoteStore(vault, index).read(id);
  } finally {
    index.close();
  }
});

/// 노트 패널·사이드바의 작은 쓰기 (11/11 검토 O-5 나머지). 하나하나는 작아 보여도 쓰기 전·후 색인 맞추기와
/// 자동 목차 다시 쓰기가 붙어, 노트 1만 개에서 편집 창 저장처럼 화면이 멈췄다.
enum NoteChange {
  /// 휴지통으로 옮긴다 (`brain undo`로 되살림).
  delete,

  /// 초안을 확정한다.
  confirm,

  /// 다른 주제 폴더로 옮긴다 ([topic] 필요).
  move,

  /// 추천 연결을 확정한다: 본문 끝에 `관련: [[linkTitle]]`.
  appendLink,

  /// 초안을 정리된 노트([targetId])에 합친다 (설계서_프롬프트이후 4.2).
  mergeInto,
}

Future<void> changeNoteInBackground(
  String vaultRoot,
  String indexPath, {
  required NoteChange change,
  required String id,
  String? topic,
  String? linkTitle,
  String? targetId,
  String? batch,
}) => Isolate.run(() {
  final vault = Vault(vaultRoot);
  final index = SearchIndex.open(vault, path: indexPath, busyTimeout: userWriteWait);
  try {
    final store = NoteStore(vault, index);
    switch (change) {
      case NoteChange.mergeInto:
        store.mergeDraftInto(id, targetId!, batch: batch);
      case NoteChange.delete:
        store.delete(id, batch: batch);
      case NoteChange.confirm:
        store.setStatus(id, NoteStatus.active, batch: batch);
      case NoteChange.move:
        store.move(id, topic!, batch: batch);
      case NoteChange.appendLink:
        final found = store.read(id);
        if (found == null) throw NoteStoreException('$id 노트가 없습니다.');
        final (_, note, hash) = found;
        store.update(
          id,
          expectHash: hash,
          title: note.title,
          summary: note.summary,
          body: '${note.body.trimRight()}\n\n관련: [[$linkTitle]]\n',
          tags: note.tags,
          aliases: note.aliases,
          batch: batch,
        );
    }
  } finally {
    index.close();
  }
});

/// 정리 대기 초안마다 비슷한 정리된 노트 최대 2개 (설계서_프롬프트이후 4.2). 초안마다 파일을 읽고 FTS 질의를 몇 번 해
/// 초안이 많으면 화면 스레드에서 멈칫한다. 보드가 떠 있을 때만 계산한다.
Future<Map<String, List<SimilarNote>>> draftSimilarInBackground(String vaultRoot, String indexPath) =>
    Isolate.run(() {
      final vault = Vault(vaultRoot);
      final index = SearchIndex.open(vault, path: indexPath, rebuildIfOld: false);
      try {
        return NoteStore(vault, index).similarForDrafts();
      } finally {
        index.close();
      }
    });

/// 정리 보드 "AI가 고친 노트" (설계서_프롬프트이후 4.3). 변경 기록 3달과 되돌리기 묶음을 읽는다.
Future<List<AiEdit>> aiEditsInBackground(String vaultRoot, String indexPath) => Isolate.run(() {
  final vault = Vault(vaultRoot);
  final index = SearchIndex.open(vault, path: indexPath, rebuildIfOld: false);
  try {
    return AiEditReview(vault, index).pending();
  } finally {
    index.close();
  }
});

/// [바뀐 내용 보기]: AI가 처음 고치기 전 본문과 지금 본문의 줄 차이. 고치기 전 사본이 없으면 null.
/// 읽기 전 색인 맞추기가 1만 개에서 약 80ms라 백그라운드에서 한다.
Future<List<DiffLine>?> aiEditDiffInBackground(String vaultRoot, String indexPath, AiEdit edit) => Isolate.run(() {
  final vault = Vault(vaultRoot);
  final index = SearchIndex.open(vault, path: indexPath, busyTimeout: userWriteWait);
  try {
    final (before, after) = AiEditReview(vault, index).beforeAfter(edit);
    return before == null ? null : lineDiff(before, after);
  } finally {
    index.close();
  }
});

/// [되돌리기]: 이 노트를 고친 AI 묶음을 최근 것부터 되돌린다. 반환: 되돌린 파일 수.
/// [NoteStoreException](사람이 그 뒤에 또 고침)·[ArgumentError](묶음이 없음)는 그대로 다시 던져진다.
Future<int> revertAiEditInBackground(String vaultRoot, String indexPath, AiEdit edit) => Isolate.run(() {
  final vault = Vault(vaultRoot);
  final index = SearchIndex.open(vault, path: indexPath, busyTimeout: userWriteWait);
  try {
    return AiEditReview(vault, index).revert(edit);
  } finally {
    index.close();
  }
});

/// 주 1회 옛 결정 점검 (설계서_프롬프트이후 4.4 (나)). 최근 7일 노트마다 비슷한 노트를 찾아 노트 1만 개(최근 300개)에서
/// 약 2초라 백그라운드에서 하고, 진행을 [onProgress](본 수, 전체 수)로 알린다.
Future<List<DecisionPair>> decisionCheckInBackground(
  String vaultRoot,
  String indexPath, {
  required void Function(int done, int total) onProgress,
}) async {
  final port = ReceivePort();
  final subscription = port.listen((message) {
    if (message case [final int done, final int total]) onProgress(done, total);
  });
  try {
    return await _decisionCheck(vaultRoot, indexPath, port.sendPort);
  } finally {
    await subscription.cancel();
    port.close();
  }
}

/// 따로 둔 까닭: 위 함수의 [onProgress] 클로저까지 isolate로 보내려다 실패하지 않게 (실수 노트 L-0004).
Future<List<DecisionPair>> _decisionCheck(String vaultRoot, String indexPath, SendPort progress) => Isolate.run(() {
  final vault = Vault(vaultRoot);
  final index = SearchIndex.open(vault, path: indexPath, busyTimeout: userWriteWait);
  try {
    return DecisionCheck(vault, index).run(onProgress: (done, total) => progress.send([done, total]));
  } finally {
    index.close();
  }
});

/// [옛 노트 보관]: 옛 노트를 합쳐짐으로 바꾸고 새 노트를 가리키게 한다 (되돌리기 묶음 하나).
Future<void> archiveOldDecisionInBackground(String vaultRoot, String indexPath, DecisionPair pair, String batch) =>
    Isolate.run(() {
      final vault = Vault(vaultRoot);
      final index = SearchIndex.open(vault, path: indexPath, busyTimeout: userWriteWait);
      try {
        DecisionCheck(vault, index).archiveOld(NoteStore(vault, index), pair, batch: batch);
      } finally {
        index.close();
      }
    });
