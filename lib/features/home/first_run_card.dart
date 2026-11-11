import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/router/app_page.dart';
import '../../app/theme/app_colors.dart';
import '../../core/app_config_provider.dart';
import '../../core/brain_providers.dart';
import '../connect/claude_code_providers.dart';

/// 첫 실행 3단계 안내 (설계서 3.0 E3): ① 지식 폴더 ② 연동 ③ 지난 대화 정리.
/// 끝난 단계는 체크로 보이고, [닫기]를 누르면 설정 `firstRunDone`에 남겨 다시 보이지 않는다.
class FirstRunCard extends ConsumerStatefulWidget {
  const FirstRunCard({super.key});

  @override
  ConsumerState<FirstRunCard> createState() => _FirstRunCardState();
}

class _FirstRunCardState extends ConsumerState<FirstRunCard> {
  /// 앱이 들고 있는 설정(appConfigProvider)을 거쳐 저장한다. 예전에는 파일에 바로 써서, 그 뒤 다른 설정
  /// (패널 너비·배율)을 저장하면 앱이 들고 있던 옛 값이 덮어써 카드가 되살아났다 (11/11 K-37).
  void _close() => ref.read(appConfigProvider.notifier).update((c) => c.copyWith(isFirstRunDone: true));

  @override
  Widget build(BuildContext context) {
    if (ref.watch(appConfigProvider.select((c) => c.isFirstRunDone))) return const SizedBox.shrink();
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final vault = ref.watch(vaultProvider);
    final hasNotes = ref.watch(notesProvider).isNotEmpty;
    final status = ref.watch(claudeCodeStatusProvider).value;
    final isConnected = status != null && status.isInstalled && status.isEnabled;
    final hasTidied = SessionRegistry(vault).load().values.any((s) => s.isDone);
    final steps = [
      ('지식 폴더 정하기', '노트(md 파일)가 저장될 폴더 — 지금: ${vault.root}', ref.read(appConfigProvider).vaultPath != null || hasNotes, AppPage.settings),
      ('Claude Code 연동', '바뀔 파일을 미리 보고 설치합니다. 우리 서버를 거치지 않습니다', isConnected, AppPage.connect),
      ('지난 대화 정리', '이 맥에 남은 Claude Code 대화에서 결정·해결 방법을 초안으로 뽑습니다', hasTidied, AppPage.connect),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: ShadCard(
        title: const Text('처음이면 세 단계만 하세요'),
        description: Text('${steps.where((s) => s.$3).length}/3 끝남', style: theme.textTheme.muted),
        footer: Align(
          alignment: Alignment.centerRight,
          child: ShadButton.ghost(size: ShadButtonSize.sm, onPressed: _close, child: const Text('닫기')),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, (title, detail, done, page)) in steps.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(
                      done ? LucideIcons.circleCheck : LucideIcons.circle,
                      size: 16,
                      color: done ? colors.accent : colors.textFaint,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${i + 1}. $title', style: theme.textTheme.small),
                          Text(detail, style: theme.textTheme.muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    if (!done)
                      ShadButton.outline(
                        size: ShadButtonSize.sm,
                        onPressed: () => context.go(page.path),
                        child: const Text('하러 가기'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
