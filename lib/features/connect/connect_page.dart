import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import 'system_check_provider.dart';

/// 연동·설정. 지금은 실행 환경 점검만 있다. 연동 설치는 3주차 (설계서 5.2).
class ConnectPage extends ConsumerWidget {
  const ConnectPage({super.key});

  void _onRecheck(WidgetRef ref) => ref.invalidate(systemCheckProvider);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final check = ref.watch(systemCheckProvider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
      children: [
        Text('연동·설정', style: theme.textTheme.h4),
        const SizedBox(height: 24),
        ShadCard(
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
                    Text(
                      'SQLite ${sqlite.version}',
                      style: theme.textTheme.small,
                    ),
                    for (final (label, ok) in sqlite.items)
                      _CheckRow(label: label, isOk: ok),
                    if (sqlite.error != null) Text(sqlite.error!),
                    const SizedBox(height: 16),
                    Text('지식 폴더 ${vault.path}', style: theme.textTheme.small),
                    for (final (label, ok) in vault.items)
                      _CheckRow(label: label, isOk: ok),
                    if (vault.error != null) Text(vault.error!),
                    const SizedBox(height: 16),
                    Text('Supabase', style: theme.textTheme.small),
                    switch (result.isSupabaseReachable) {
                      null => Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '설정 전 — env/supabase.json을 만들고 '
                          '--dart-define-from-file로 실행',
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
        ),
        const SizedBox(height: 16),
        const ShadCard(
          title: Text('한글 입력 시험'),
          description: Text('글자를 조합하는 동안 밑줄이 보이고, 조합이 끝나면 글자가 바르게 남아야 합니다.'),
          child: Padding(
            padding: EdgeInsets.only(top: 16),
            child: ShadInput(placeholder: Text('여기에 한글을 입력해 보세요')),
          ),
        ),
      ],
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
          Text(label),
        ],
      ),
    );
  }
}
