import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/router/app_page.dart';
import '../app/theme/app_colors.dart';
import '../core/brain_providers.dart';
import '../features/notes/note_editor_dialog.dart';
import '../features/notes/note_panel.dart';
import 'command_palette.dart';
import 'sidebar.dart';

/// 3단 배치: 사이드바 · 가운데 · 오른쪽 노트 (설계서 3.2). 창이 좁으면 오른쪽을 접는다.
/// 단축키: ⌘K 명령 창, ⌘N 새 노트, ⌘, 설정 (macOS 관례).
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.current, required this.child});

  static const _rightPanelMinWindow = 1100.0;

  final AppPage current;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    // 좁은 창에서는 접어 두었다가 노트를 고르면 연다 (× 로 닫음).
    final showRight =
        MediaQuery.sizeOf(context).width >= _rightPanelMinWindow ||
        ref.watch(selectedNoteProvider) != null;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            showCommandPalette(context),
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () =>
            showNoteEditor(context),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
            context.go(AppPage.settings.path),
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: colors.background,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Sidebar(current: current),
              Expanded(child: child),
              if (showRight) const NotePanel(),
            ],
          ),
        ),
      ),
    );
  }
}
