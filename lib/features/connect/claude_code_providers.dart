import 'dart:io';
import 'dart:isolate';

import 'package:brain_core/brain_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/brain_providers.dart';
import '../../core/claude_code.dart';

/// Claude Code가 있는지, 플러그인이 깔렸는지.
final claudeCodeStatusProvider = FutureProvider<ClaudeCodeStatus>(
  (ref) => ref.watch(claudeCodeProvider).status(),
);

/// 지난 대화 정리 상태 (설계서 5.2 연동 직후 지난 대화 자동 정리).
class PastSessionsState {
  const PastSessionsState({
    this.sessions = const [],
    this.statuses = const {},
    this.excludedProjects = const {},
    this.isLoading = false,
    this.isRunning = false,
    this.done = 0,
    this.total = 0,
    this.current,
    this.log = const [],
    this.error,
  });

  final List<ClaudeSession> sessions;
  final Map<String, SessionStatus> statuses;
  final Set<String> excludedProjects;
  final bool isLoading;
  final bool isRunning;
  final int done;
  final int total;
  final ClaudeSession? current;
  final List<String> log;
  final String? error;

  bool get isLoaded => sessions.isNotEmpty || (!isLoading && log.isNotEmpty);

  /// 프로젝트별 아직 정리 안 한 세션 수.
  Map<String, int> get unsavedByProject {
    final counts = <String, int>{};
    for (final s in sessions) {
      if (statuses[s.sessionId]?.isDone ?? false) continue;
      counts.update(s.project, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  List<ClaudeSession> get targets => [
    for (final s in sessions)
      if (!(statuses[s.sessionId]?.isDone ?? false) &&
          !excludedProjects.contains(s.project))
        s,
  ];

  PastSessionsState copyWith({
    List<ClaudeSession>? sessions,
    Map<String, SessionStatus>? statuses,
    Set<String>? excludedProjects,
    bool? isLoading,
    bool? isRunning,
    int? done,
    int? total,
    ClaudeSession? current,
    bool clearCurrent = false,
    List<String>? log,
    String? error,
    bool clearError = false,
  }) => PastSessionsState(
    sessions: sessions ?? this.sessions,
    statuses: statuses ?? this.statuses,
    excludedProjects: excludedProjects ?? this.excludedProjects,
    isLoading: isLoading ?? this.isLoading,
    isRunning: isRunning ?? this.isRunning,
    done: done ?? this.done,
    total: total ?? this.total,
    current: clearCurrent ? null : (current ?? this.current),
    log: log ?? this.log,
    error: clearError ? null : (error ?? this.error),
  );
}

class PastSessionsController extends Notifier<PastSessionsState> {
  Process? _process;
  bool _isStopRequested = false;

  @override
  PastSessionsState build() => const PastSessionsState();

  /// 세션 기록을 읽는다. 처음에는 수백 MB를 읽어 몇 초 걸리므로 별도 isolate에서 한다.
  Future<void> load() async {
    final vault = ref.read(vaultProvider);
    state = state.copyWith(isLoading: true, clearError: true);
    final root = vault.root;
    final indexPath = vault.indexPath;
    final sessions = await Isolate.run(() {
      final v = Vault(root);
      final index = SearchIndex.open(v, path: indexPath);
      try {
        return ClaudeSessions(cacheDb: index.db)
            .list(vault: v, since: const Duration(days: 90));
      } finally {
        index.close();
      }
    });
    state = state.copyWith(
      sessions: sessions,
      statuses: SessionRegistry(vault).load(),
      isLoading: false,
    );
  }

  void toggleProject(String project) {
    final excluded = {...state.excludedProjects};
    excluded.contains(project)
        ? excluded.remove(project)
        : excluded.add(project);
    state = state.copyWith(excludedProjects: excluded);
  }

  void stop() {
    _isStopRequested = true;
    _process?.kill();
  }

  /// 고른 세션을 하나씩 사용자 AI로 정리한다. 실패하면 축약 원본만 남긴다.
  Future<void> run() async {
    final vault = ref.read(vaultProvider);
    final claude = ref.read(claudeCodeProvider);
    final targets = state.targets;
    _isStopRequested = false;
    state = state.copyWith(
      isRunning: true,
      done: 0,
      total: targets.length,
      log: [],
      clearError: true,
    );
    final sessions = ClaudeSessions();
    for (final session in targets) {
      if (_isStopRequested) break;
      state = state.copyWith(current: session);
      final result = await claude.saveSession(
        session,
        onStart: (p) => _process = p,
      );
      _process = null;
      final line = StringBuffer('${session.shortId} ${session.project} — ');
      if (result.ok) {
        line.write(
          result.message.isEmpty ? '정리함' : result.message.split('\n').first,
        );
      } else if (_isStopRequested) {
        line.write('멈춤');
      } else {
        // 실패해도 대화 문장은 남겨 두고, 나중에 스킬로 정리할 수 있게 한다.
        final root = vault.root;
        final rel = await Isolate.run(
          () => archiveSession(Vault(root), sessions, session),
        );
        line.write('실패, 원본만 저장 ($rel): ${result.message}');
      }
      state = state.copyWith(
        done: state.done + 1,
        log: [...state.log, line.toString()],
        statuses: SessionRegistry(vault).load(),
      );
      if (result.needsLogin) {
        state = state.copyWith(
          error: '터미널 Claude Code 로그인이 필요합니다. 터미널에서 claude를 실행해 /login 한 뒤 다시 시작하세요.',
        );
        break;
      }
    }
    state = state.copyWith(isRunning: false, clearCurrent: true);
    ref.invalidate(notesProvider);
  }
}

final pastSessionsProvider =
    NotifierProvider<PastSessionsController, PastSessionsState>(
      PastSessionsController.new,
    );
