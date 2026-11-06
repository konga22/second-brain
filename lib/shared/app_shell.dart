import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../app/router/app_page.dart';
import '../app/theme/app_colors.dart';
import 'sidebar.dart';

/// 3단 배치: 사이드바 · 가운데 · 오른쪽 노트 (설계서 3.2). 창이 좁으면 오른쪽을 접는다.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.current, required this.child});

  static const _rightPanelMinWindow = 1100.0;

  final AppPage current;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final showRight = MediaQuery.sizeOf(context).width >= _rightPanelMinWindow;
    return ColoredBox(
      color: colors.background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Sidebar(current: current),
          Expanded(child: child),
          if (showRight) const _NotePanel(),
        ],
      ),
    );
  }
}

class _NotePanel extends StatelessWidget {
  const _NotePanel();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.border)),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Text(
        '노트를 고르면 여기에 열립니다',
        style: ShadTheme.of(context).textTheme.muted,
      ),
    );
  }
}
