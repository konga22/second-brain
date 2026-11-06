import 'dart:async';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_config_provider.dart';
import '../../core/brain_providers.dart';
import '../../core/session_listing.dart';
import 'claude_code_providers.dart';

/// 자동 정리 상태 (연동 화면에 보여 준다).
class AutoTidyState {
  const AutoTidyState({
    this.isRunning = false,
    this.step = '',
    this.lastRunAt,
    this.log = const [],
  });

  final bool isRunning;
  final String step;
  final DateTime? lastRunAt;
  final List<String> log;
}

/// 자동 정리: 저장 안 한 세션을 하루 비용 상한 안에서 앱이 알아서 정리한다 (설계서 5.6 안전망).
///
/// 대화 중 자동 저장(세션 시작 훅)으로 대부분 들어오고, 여기서는 그래도 빠진 세션만 다룬다.
/// - 앱이 켜진 지 2분 뒤 한 번, 그 뒤 6시간마다
/// - 끝난 세션만(최근 30분 안 기록은 진행 중으로 보고 뺌), 짧은 세션부터
/// - 사용자 대화 150개가 넘는 긴 세션은 비용이 커서 건너뛴다 (연동 화면에서 직접 정리)
/// - 실제 비용을 더해 하루 상한에 닿으면 멈춘다
class AutoTidyController extends Notifier<AutoTidyState> {
  static const firstDelay = Duration(minutes: 2);
  static const interval = Duration(hours: 6);
  static const maxUserMessages = 150;

  Timer? _timer;

  @override
  AutoTidyState build() {
    _timer = Timer(firstDelay, _tick);
    ref.onDispose(() => _timer?.cancel());
    return const AutoTidyState();
  }

  void _tick() {
    run();
    _timer = Timer(interval, _tick);
  }

  String get _today => formatTime(DateTime.now()).substring(0, 10);

  double spentToday(AppConfig c) =>
      c.autoTidySpentDay == _today ? c.autoTidySpentUsd : 0;

  /// 정리할 세션: 저장 안 함 · 끝남(최근 30분 기록 없음) · 사용자 대화 150개 이하, 짧은 것부터.
  static Future<List<ClaudeSession>> _targets(Vault vault) async {
    final sessions = await listSessionsInBackground(vault.root, vault.indexPath);
    final statuses = SessionRegistry(vault).load();
    return [
      for (final s in sessions)
        if (!(statuses[s.sessionId]?.isDone ?? false) &&
            !PastSessionsState.isActive(s) &&
            s.userCount <= maxUserMessages)
          s,
    ]..sort((a, b) => a.userCount.compareTo(b.userCount));
  }

  /// 미리 보기: 정리하지 않고 대상 세션만 센다 (비용 없음). 설정 화면에 "정리 대상 N개"로 보인다.
  Future<List<ClaudeSession>> preview() => _targets(ref.read(vaultProvider));

  Future<void> run() async {
    final config = ref.read(appConfigProvider);
    if (!config.isAutoTidyOn || state.isRunning) return;
    // 사용자가 연동 화면에서 직접 정리 중이면 겹치지 않게 쉰다.
    if (ref.read(pastSessionsProvider).isRunning) return;
    if (spentToday(config) >= config.autoTidyDailyUsd) return;
    final vault = ref.read(vaultProvider);
    final claude = ref.read(claudeCodeProvider);
    state = AutoTidyState(isRunning: true, step: '세션 목록 읽는 중', log: state.log);
    final log = <String>[];
    try {
      final targets = await _targets(vault);
      for (final session in targets) {
        final now = ref.read(appConfigProvider);
        if (spentToday(now) >= now.autoTidyDailyUsd || !now.isAutoTidyOn) break;
        state = AutoTidyState(
          isRunning: true,
          step: '${session.project} ${session.shortId} 정리 중',
          log: log,
        );
        final result = await claude.saveSession(session);
        final cost = result.costUsd ?? 0;
        ref
            .read(appConfigProvider.notifier)
            .update(
              (c) => c.copyWith(
                autoTidySpentDay: _today,
                autoTidySpentUsd: spentToday(c) + cost,
              ),
            );
        final outcome = result.ok
            ? '정리함'
            : '실패: ${result.message.split('\n').first}';
        log.add(
          '${session.shortId} ${session.project} — $outcome (약 ${cost.toStringAsFixed(2)}달러)',
        );
        if (result.needsLogin) {
          log.add('터미널에서 claude → /login 이 필요합니다. 자동 정리를 멈췄습니다.');
          break;
        }
      }
      if (targets.isEmpty) log.add('정리할 세션 없음');
    } on Object catch (e, stack) {
      debugPrint('[자동 정리] 오류: $e\n$stack');
      log.add('자동 정리 오류: $e');
    } finally {
      state = AutoTidyState(isRunning: false, lastRunAt: DateTime.now(), log: log);
      ref.read(vaultRevisionProvider.notifier).bump();
    }
  }
}

final autoTidyProvider = NotifierProvider<AutoTidyController, AutoTidyState>(
  AutoTidyController.new,
);
