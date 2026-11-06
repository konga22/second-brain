import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../app/router/app_page.dart';

/// 아직 만들지 않은 화면 자리.
class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage({super.key, required this.page});

  final AppPage page;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '${page.label} 화면은 준비 중입니다',
        style: ShadTheme.of(context).textTheme.muted,
      ),
    );
  }
}
