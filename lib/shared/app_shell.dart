import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../app/router/app_page.dart';
import '../app/theme/app_colors.dart';
import '../core/app_config_provider.dart';
import '../core/brain_providers.dart';
import '../features/connect/auto_tidy.dart';
import '../features/home/decision_check_provider.dart';
import '../features/notes/note_editor_dialog.dart';
import '../features/notes/note_panel.dart';
import 'command_palette.dart';
import 'sidebar.dart';

/// 3단 배치: 사이드바 · 가운데 · 오른쪽 노트 (설계서 3.2).
/// 오른쪽 패널은 열고 닫고(⌘\) 경계를 끌어 너비를 바꾼다. 창이 좁으면 노트를 고를 때만 연다.
/// 단축키: ⌘K 명령 창, ⌘N 새 노트, ⌘, 설정, ⌘+ ⌘- ⌘0 화면 배율.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.current, required this.child});

  static const _rightPanelMinWindow = 1100.0;
  static const minPanel = 260.0;
  static const maxPanel = 680.0;

  final AppPage current;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final config = ref.watch(appConfigProvider);
    // 자동 정리 타이머를 앱과 함께 띄운다 (설정에서 켰을 때만 실제로 돈다).
    ref.watch(autoTidyProvider);
    // 주 1회 옛 결정 점검 타이머도 앱과 함께 띄운다. 진행이 바뀔 때마다 셸을 다시 그리지 않게 listen으로 붙잡는다.
    ref.listen(decisionCheckProvider, (_, _) {});
    final configNotifier = ref.read(appConfigProvider.notifier);
    final selected = ref.watch(selectedNoteProvider);
    // 패널을 닫아 둔 상태에서 노트를 고르면 연다.
    ref.listen(selectedNoteProvider, (previous, next) {
      if (next != null &&
          next != previous &&
          !ref.read(appConfigProvider).isPanelOpen) {
        configNotifier.update((c) => c.copyWith(isPanelOpen: true));
      }
    });
    final isWide = MediaQuery.sizeOf(context).width >= _rightPanelMinWindow;
    final showRight = config.isPanelOpen && (isWide || selected != null);
    void togglePanel() =>
        configNotifier.update((c) => c.copyWith(isPanelOpen: !c.isPanelOpen));
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            showCommandPalette(context),
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () =>
            showNoteEditor(context),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
            context.go(AppPage.settings.path),
        const SingleActivator(LogicalKeyboardKey.backslash, meta: true):
            togglePanel,
        const SingleActivator(LogicalKeyboardKey.equal, meta: true): () =>
            configNotifier.zoom(1),
        const SingleActivator(
          LogicalKeyboardKey.equal,
          meta: true,
          shift: true,
        ): () =>
            configNotifier.zoom(1),
        const SingleActivator(LogicalKeyboardKey.minus, meta: true): () =>
            configNotifier.zoom(-1),
        const SingleActivator(LogicalKeyboardKey.digit0, meta: true): () =>
            configNotifier.zoom(0),
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: colors.background,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Sidebar(current: current),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: child),
                    if (!showRight)
                      Positioned(
                        top: 30,
                        right: 8,
                        child: ShadTooltip(
                          builder: (_) => const Text('노트 패널 열기 (⌘\\)'),
                          child: ShadIconButton.ghost(
                            width: 30,
                            height: 30,
                            icon: const Icon(
                              LucideIcons.panelRightOpen,
                              size: 16,
                            ),
                            onPressed: togglePanel,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (showRight) ...[
                MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) => configNotifier.update(
                      (c) => c.copyWith(
                        panelWidth: (c.panelWidth - d.delta.dx).clamp(
                          minPanel,
                          maxPanel,
                        ),
                      ),
                      save: false,
                    ),
                    onHorizontalDragEnd: (_) =>
                        ref.read(appConfigProvider).save(),
                    child: Container(
                      width: 5,
                      color: colors.border.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                // 패널은 창 폭의 35%를 넘지 않는다 (가운데 화면이 너무 좁아지지 않게).
                NotePanel(
                  width: config.panelWidth
                      .clamp(minPanel, MediaQuery.sizeOf(context).width * 0.35)
                      .toDouble(),
                  onClose: togglePanel,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
