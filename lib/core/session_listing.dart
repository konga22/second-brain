import 'dart:isolate';

import 'package:brain_core/brain_core.dart';

/// 지난 Claude Code 세션 목록을 백그라운드(isolate)에서 읽는다. 처음에는 수백 MB를 읽어 몇 초 걸린다.
///
/// 최상위 함수로 둔다: 클래스 메서드 안에서 `Isolate.run`에 클로저를 넘기면 그 객체(타이머·Ref 등
/// 보낼 수 없는 것)까지 함께 넘어가 "object is unsendable"로 실패한다 (사용기 #19).
/// 세션별 축약본 글자 수 (설계서 3.0 E1 정리 비용 어림). 경로만 넘겨 isolate에서 다시 읽는다 (L-0004).
Future<Map<String, int>> condensedSizesInBackground(
  String vaultRoot,
  String indexPath,
  List<String> paths,
) => Isolate.run(() {
  final vault = Vault(vaultRoot);
  final index = SearchIndex.open(vault, path: indexPath);
  try {
    final sessions = ClaudeSessions(cacheDb: index.db);
    final wanted = paths.toSet();
    return {
      for (final s in sessions.list(vault: vault, since: const Duration(days: 3650)))
        if (wanted.contains(s.path)) s.path: sessions.condense(s).length,
    };
  } finally {
    index.close();
  }
});

Future<List<ClaudeSession>> listSessionsInBackground(
  String vaultRoot,
  String indexPath, {
  Duration since = const Duration(days: 90),
}) => Isolate.run(() {
  final vault = Vault(vaultRoot);
  final index = SearchIndex.open(vault, path: indexPath);
  try {
    return ClaudeSessions(cacheDb: index.db).list(vault: vault, since: since);
  } finally {
    index.close();
  }
});
