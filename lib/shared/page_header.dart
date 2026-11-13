import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 화면 머리 줄: 제목·부제는 왼쪽, 버튼은 오른쪽. 폭이 모자라면 버튼이 다음 줄로 내려간다
/// (좁은 창·큰 화면 배율에서 넘치지 않게, 11/07 실수 노트 L-0005).
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 12,
          children: [
            Text(title, style: theme.textTheme.h4),
            if (subtitle != null) Text(subtitle!, style: theme.textTheme.muted),
          ],
        ),
        if (actions.isNotEmpty)
          Wrap(spacing: 8, runSpacing: 6, children: actions),
      ],
    );
  }
}
