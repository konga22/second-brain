import 'package:go_router/go_router.dart';

import '../../features/connect/connect_page.dart';
import '../../features/home/home_page.dart';
import '../../shared/app_shell.dart';
import '../../shared/placeholder_page.dart';
import 'app_page.dart';

final appRouter = GoRouter(
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(current: AppPage.fromPath(state.uri.path), child: child),
      routes: [
        for (final page in AppPage.values)
          GoRoute(
            path: page.path,
            name: page.name,
            builder: (context, state) => switch (page) {
              AppPage.home => const HomePage(),
              AppPage.connect => const ConnectPage(),
              _ => PlaceholderPage(page: page),
            },
          ),
      ],
    ),
  ],
);
