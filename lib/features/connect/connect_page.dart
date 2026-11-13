import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/brain_providers.dart';
import '../../core/claude_code.dart';
import '../persona/persona_card.dart';
import 'claude_code_providers.dart';
import 'system_check_provider.dart';
import '../../shared/safe_set_state.dart';

/// 연동: Claude Code 연동, 나에 대해 4문항(설계서_프롬프트이후 5.2), 지난 대화 정리, 실행 환경 점검 (설계서 5.2).
class ConnectPage extends ConsumerWidget {
  const ConnectPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final status = ref.watch(claudeCodeStatusProvider).value;
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
      children: [
        Text('연동', style: theme.textTheme.h4),
        const SizedBox(height: 24),
        const _ClaudeCodeCard(),
        // 연동 다음 단계: 4문항 (설계서_프롬프트이후 5.2)
        PersonaStep(isConnected: status != null && status.isInstalled && status.isEnabled),
        const SizedBox(height: 16),
        const _PastSessionsCard(),
        const SizedBox(height: 16),
        const _SystemCheckCard(),
      ],
    );
  }
}

class _ClaudeCodeCard extends ConsumerStatefulWidget {
  const _ClaudeCodeCard();

  @override
  ConsumerState<_ClaudeCodeCard> createState() => _ClaudeCodeCardState();
}

class _ClaudeCodeCardState extends ConsumerState<_ClaudeCodeCard> with SafeSetState<_ClaudeCodeCard> {
  bool _isWorking = false;
  List<String> _log = const [];
  String? _error;

  Future<void> _onInstall() async {
    final claude = ref.read(claudeCodeProvider);
    final isConfirmed = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('Claude Code에 연동할까요?'),
        description: const Text('아래 내용이 바뀝니다. 해제하면 우리가 넣은 것만 지웁니다.'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('연동'),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in claude.plannedChanges()) Text('• $line'),
          ],
        ),
      ),
    );
    if (isConfirmed != true) return;
    setState(() {
      _isWorking = true;
      _error = null;
    });
    try {
      final log = await claude.install();
      setState(() => _log = log);
    } on ClaudeCodeException catch (e) {
      setState(() => _error = e.message);
    } on Object catch (e) {
      setState(() => _error = '설치하지 못했습니다: $e');
    } finally {
      setState(() => _isWorking = false);
      if (mounted) ref.invalidate(claudeCodeStatusProvider);
    }
  }

  Future<void> _onUninstall() async {
    setState(() => _isWorking = true);
    try {
      await ref.read(claudeCodeProvider).uninstall();
      setState(() => _log = const ['연동 해제함']);
    } on Object catch (e) {
      // 실패해도 "…중"에 멈추지 않는다 (11/11 K-37)
      setState(() => _error = '연동을 해제하지 못했습니다: $e');
    } finally {
      setState(() => _isWorking = false);
      if (mounted) ref.invalidate(claudeCodeStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final status = ref.watch(claudeCodeStatusProvider);
    return ShadCard(
      title: const Text('Claude Code'),
      description: const Text(
        '스킬 4개(찾기·지식 저장·원본 정리·점검), 검증 에이전트, 훅 3개를 플러그인으로 설치합니다. 우리 서버를 거치지 않습니다.',
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: status.when(
          loading: () => const Text('확인 중…'),
          error: (e, _) => Text('확인 실패: $e'),
          data: (s) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CheckRow(
                label: s.isFound
                    ? 'Claude Code ${s.version} (${s.executable})'
                    : 'Claude Code를 찾지 못함',
                isOk: s.isFound,
              ),
              _CheckRow(
                label: s.isInstalled
                    ? '플러그인 설치됨${s.isEnabled ? '' : ' (꺼짐)'}'
                    : '플러그인 없음',
                isOk: s.isInstalled && s.isEnabled,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  ShadButton(
                    size: ShadButtonSize.sm,
                    enabled: s.isFound && !_isWorking,
                    onPressed: _onInstall,
                    child: Text(s.isInstalled ? '다시 설치' : '연동'),
                  ),
                  const SizedBox(width: 8),
                  if (s.isInstalled)
                    ShadButton.outline(
                      size: ShadButtonSize.sm,
                      enabled: !_isWorking,
                      onPressed: _onUninstall,
                      child: const Text('해제'),
                    ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!),
                ),
              for (final line in _log) Text(line, style: theme.textTheme.muted),
              const SizedBox(height: 8),
              Text(
                '설치한 뒤 Claude Code를 새로 열면 적용됩니다. 대화 중에 "지식 저장해 줘"라고 하면 정리 대기에 노트가 생깁니다.',
                style: theme.textTheme.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PastSessionsCard extends ConsumerWidget {
  const _PastSessionsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final state = ref.watch(pastSessionsProvider);
    final controller = ref.read(pastSessionsProvider.notifier);
    final projects = state.unsavedByProject.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ShadCard(
      title: const Text('지난 대화 정리'),
      description: const Text(
        '이 맥에 남은 Claude Code 대화(최근 90일)에서 지식을 뽑아 정리 대기에 넣습니다. '
        'Claude Code는 오래된 기록을 30일 뒤 지우므로 연동할 때 한 번 정리해 두는 것이 좋습니다.',
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!state.isLoaded)
              ShadButton.outline(
                size: ShadButtonSize.sm,
                enabled: !state.isLoading,
                onPressed: controller.load,
                child: Text(state.isLoading ? '세션 기록 읽는 중…' : '세션 목록 불러오기'),
              ),
            if (state.isLoaded && projects.isEmpty && !state.isRunning)
              Text('정리할 세션이 없습니다.', style: theme.textTheme.muted),
            if (projects.isNotEmpty) ...[
              Row(
                children: [
                  Text('정리할 프로젝트 (체크를 빼면 제외)', style: theme.textTheme.small),
                  const Spacer(),
                  ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    enabled: !state.isRunning,
                    onPressed: () => controller.selectAll(true),
                    child: const Text('전체 선택'),
                  ),
                  ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    enabled: !state.isRunning,
                    onPressed: () => controller.selectAll(false),
                    child: const Text('전체 해제'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (final entry in projects)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      ShadCheckbox(
                        value: !state.excludedProjects.contains(entry.key),
                        enabled: !state.isRunning,
                        onChanged: (_) => controller.toggleProject(entry.key),
                      ),
                      const SizedBox(width: 8),
                      Text('${entry.key}  ·  세션 ${entry.value}개'),
                    ],
                  ),
                ),
              if (state.activeCount > 0)
                Text(
                  '최근 30분 안에 기록된 대화 ${state.activeCount}개는 아직 진행 중일 수 있어 뺐습니다.',
                  style: theme.textTheme.muted,
                ),
              const SizedBox(height: 12),
              // E1 정리 비용 어림 (설계서 3.0)
              Text(
                state.targetChars == null
                    ? '비용 어림 계산 중…'
                    : state.targetChars == 0 && state.targets.isNotEmpty
                    ? '비용 어림 못 함 (아래 오류 참고)'
                    : '축약 약 ${(state.targetChars! / 10000).toStringAsFixed(1)}만 자 · 어림 \$${(state.targetChars! / 100000 * PastSessionsState.usdPer100kChars).toStringAsFixed(2)} '
                          '(실측 10만 자당 약 \$1.4, 모델·세션에 따라 ±50%)',
                style: theme.textTheme.small,
              ),
              const SizedBox(height: 4),
              Text(
                '선택한 세션 ${state.targets.length}개를 정리합니다. 사용자의 Claude Code 사용량(토큰)을 씁니다. '
                'Claude Code는 brain 명령만 쓸 수 있게 묶어서 실행합니다.',
                style: theme.textTheme.muted,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  ShadButton(
                    size: ShadButtonSize.sm,
                    enabled: !state.isRunning && state.targets.isNotEmpty,
                    onPressed: controller.run,
                    child: const Text('동의하고 정리 시작'),
                  ),
                  const SizedBox(width: 8),
                  if (state.isRunning)
                    ShadButton.outline(
                      size: ShadButtonSize.sm,
                      onPressed: controller.stop,
                      child: const Text('멈추기'),
                    ),
                ],
              ),
            ],
            if (state.isRunning || state.total > 0) ...[
              const SizedBox(height: 12),
              ShadProgress(
                value: state.total == 0 ? 0 : state.done / state.total,
              ),
              const SizedBox(height: 4),
              Text(
                state.isRunning
                    ? '${state.done}/${state.total} · 정리 중: ${state.current?.project ?? ''} ${state.current?.shortId ?? ''}'
                    : '${state.done}/${state.total} 끝',
                style: theme.textTheme.muted,
              ),
              if (state.isRunning && state.current != null)
                Text(
                  '${state.step} · ${_formatElapsed(state.elapsed)} (긴 대화는 몇 분 걸립니다)',
                  style: theme.textTheme.muted,
                ),
            ],
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(state.error!),
              ),
            for (final line in state.log)
              Text(line, style: theme.textTheme.muted),
          ],
        ),
      ),
    );
  }
}

String _formatElapsed(Duration d) => d.inMinutes == 0
    ? '${d.inSeconds}초'
    : '${d.inMinutes}분 ${d.inSeconds % 60}초';

class _SystemCheckCard extends ConsumerWidget {
  const _SystemCheckCard();

  void _onRecheck(WidgetRef ref) => ref.invalidate(systemCheckProvider);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final check = ref.watch(systemCheckProvider);
    return ShadCard(
      title: const Text('실행 환경 점검'),
      trailing: ShadButton.outline(
        size: ShadButtonSize.sm,
        onPressed: () => _onRecheck(ref),
        leading: const Icon(LucideIcons.refreshCw, size: 14),
        child: const Text('다시 점검'),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: check.when(
          loading: () => const Text('점검 중…'),
          error: (e, _) => Text('점검 실패: $e'),
          data: (result) {
            final sqlite = result.sqlite;
            final vault = result.vault;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SQLite ${sqlite.version}', style: theme.textTheme.small),
                for (final (label, ok) in sqlite.items)
                  _CheckRow(label: label, isOk: ok),
                if (sqlite.error != null) Text(sqlite.error!),
                const SizedBox(height: 16),
                Text('지식 폴더 ${vault.path}', style: theme.textTheme.small),
                for (final (label, ok) in vault.items)
                  _CheckRow(label: label, isOk: ok),
                if (vault.error != null) Text(vault.error!),
                if (result.gitExposure case final exposure?)
                  _WarningRow(text: exposure.warning),
                const SizedBox(height: 16),
                Text('Supabase', style: theme.textTheme.small),
                switch (result.isSupabaseReachable) {
                  null => Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '설정 전 — env/supabase.json을 만들고 --dart-define-from-file로 실행',
                      style: theme.textTheme.muted,
                    ),
                  ),
                  final ok => _CheckRow(label: '서버 연결', isOk: ok),
                },
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.isOk});

  final String label;
  final bool isOk;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(
            isOk ? LucideIcons.circleCheck : LucideIcons.circleX,
            size: 16,
            color: isOk ? colors.success : colors.danger,
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(label)),
        ],
      ),
    );
  }
}

/// 실패는 아니지만 사용자가 알아야 하는 점검 결과 (설계서_프롬프트이후 4.6 GitHub 경고).
class _WarningRow extends StatelessWidget {
  const _WarningRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.triangleAlert, size: 16, color: colors.warning),
          const SizedBox(width: 8),
          Flexible(child: Text(text)),
        ],
      ),
    );
  }
}
