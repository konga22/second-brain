import 'dart:async';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/background_tasks.dart';
import '../../core/brain_providers.dart';

/// 옛 결정 점검 상태 (정리 보드 "점검 필요" 칸 위에 보인다).
class DecisionCheckState {
  const DecisionCheckState({this.isRunning = false, this.done = 0, this.total = 0, this.lastRunAt, this.error});

  final bool isRunning;
  final int done;
  final int total;
  final DateTime? lastRunAt;

  /// 마지막 점검이 실패했으면 그 까닭.
  final String? error;
}

/// 주 1회 옛 결정 점검 (설계서_프롬프트이후 4.4 (나)): AI 호출 없이 최근 7일 노트를 같은 주제의 더 오래된 비슷한 노트와 짝짓는다.
///
/// - 앱이 켜진 지 1분 뒤(시작 색인과 겹치지 않게), 그 뒤 6시간마다 "마지막 점검에서 7일 지났나"를 보고 돈다
///   (앱을 며칠 켜 두어도 주 1회).
/// - [run]은 정리 보드의 [지금 점검]도 부른다.
class DecisionCheckController extends Notifier<DecisionCheckState> {
  static const firstDelay = Duration(minutes: 1);
  static const tickEvery = Duration(hours: 6);

  Timer? _timer;

  @override
  DecisionCheckState build() {
    _timer = Timer(firstDelay, _tick);
    ref.onDispose(() => _timer?.cancel());
    DateTime? last;
    try {
      last = DecisionCheck(ref.read(vaultProvider), ref.read(searchIndexProvider)).lastRun;
    } on Object catch (e) {
      debugPrint('[옛 결정 점검] 마지막 시각을 읽지 못함: $e');
    }
    return DecisionCheckState(lastRunAt: last);
  }

  void _tick() {
    try {
      if (DecisionCheck(ref.read(vaultProvider), ref.read(searchIndexProvider)).isDue()) unawaited(run());
    } on Object catch (e) {
      debugPrint('[옛 결정 점검] 확인 실패: $e');
    }
    _timer = Timer(tickEvery, _tick);
  }

  Future<void> run() async {
    if (state.isRunning) return;
    final last = state.lastRunAt;
    state = DecisionCheckState(isRunning: true, lastRunAt: last);
    final vault = ref.read(vaultProvider);
    try {
      await decisionCheckInBackground(
        vault.root,
        vault.indexPath,
        onProgress: (done, total) {
          if (ref.mounted) state = DecisionCheckState(isRunning: true, done: done, total: total, lastRunAt: last);
        },
      );
      if (ref.mounted) state = DecisionCheckState(lastRunAt: DateTime.now());
    } on Object catch (e, stack) {
      debugPrint('[옛 결정 점검] 실패: $e\n$stack');
      if (ref.mounted) state = DecisionCheckState(lastRunAt: last, error: '$e');
    } finally {
      if (ref.mounted) ref.invalidate(decisionPairsProvider);
    }
  }
}

final decisionCheckProvider = NotifierProvider<DecisionCheckController, DecisionCheckState>(
  DecisionCheckController.new,
);

/// "옛 결정일 수 있음" 카드: 지난 점검이 찾은 짝 중 두 노트가 다 정리됨이고 [둘 다 맞음]을 누르지 않은 것.
/// 파일 하나와 짝마다 색인 한 줄만 읽어 가볍다.
final decisionPairsProvider = Provider.autoDispose<List<DecisionPair>>((ref) {
  ref.watch(vaultRevisionProvider);
  try {
    return DecisionCheck(ref.watch(vaultProvider), ref.watch(searchIndexProvider)).pending();
  } on Object catch (e) {
    debugPrint('[옛 결정 점검] 짝을 읽지 못함: $e');
    return const [];
  }
});
