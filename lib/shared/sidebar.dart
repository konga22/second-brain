import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../app/router/app_page.dart';
import '../app/theme/app_colors.dart';
import '../features/connect/system_check_provider.dart';

class Sidebar extends ConsumerWidget {
  const Sidebar({super.key, required this.current});

  final AppPage current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final theme = ShadTheme.of(context);
    // 앱을 켜면 바로 점검하고, 문제가 있으면 연동·설정 옆에 점을 붙인다.
    final hasProblem = ref.watch(
      systemCheckProvider.select(
        (check) => switch (check) {
          AsyncData(value: (final sqlite, final vault)) =>
            !sqlite.isReady || !vault.isReady,
          AsyncError() => true,
          _ => false,
        },
      ),
    );
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: colors.sidebar,
        border: Border(right: BorderSide(color: colors.border)),
      ),
      // 위쪽 28은 macOS 창 신호등 버튼 자리
      padding: const EdgeInsets.fromLTRB(10, 28, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
            child: Text('세컨드 브레인', style: theme.textTheme.large),
          ),
          for (final page in AppPage.values)
            _SidebarItem(
              page: page,
              isSelected: page == current,
              hasProblem: page == AppPage.connect && hasProblem,
            ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.page,
    required this.isSelected,
    required this.hasProblem,
  });

  final AppPage page;
  final bool isSelected;
  final bool hasProblem;

  void _onTap(BuildContext context) => context.go(page.path);

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final color = isSelected ? colors.accentText : colors.textMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ShadButton.ghost(
        onPressed: () => _onTap(context),
        mainAxisAlignment: MainAxisAlignment.start,
        backgroundColor: isSelected ? colors.accentSoft : null,
        leading: Icon(page.icon, size: 16, color: color),
        trailing: hasProblem
            ? Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: colors.danger,
                  shape: BoxShape.circle,
                ),
              )
            : null,
        child: Text(page.label, style: TextStyle(color: color)),
      ),
    );
  }
}
