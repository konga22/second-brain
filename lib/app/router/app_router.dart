import 'package:go_router/go_router.dart';

import '../../features/billing/pricing_page.dart';
import '../../features/chat/chat_page.dart';
import '../../features/connect/connect_page.dart';
import '../../features/home/home_page.dart';
import '../../features/import/import_page.dart';
import '../../features/lessons/lessons_page.dart';
import '../../features/notes/notes_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/todos/todos_page.dart';
import '../../shared/app_shell.dart';
import 'app_page.dart';

/// 개발 중 시험용: `--dart-define=START_PAGE=/notes`로 첫 화면을 바꾼다.
const _startPage = String.fromEnvironment('START_PAGE', defaultValue: '/');

final appRouter = GoRouter(
  initialLocation: _startPage,
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
              AppPage.notes => const NotesPage(),
              AppPage.chat => const ChatPage(),
              AppPage.pricing => const PricingPage(),
              AppPage.lessons => const LessonsPage(),
              AppPage.todos => const TodosPage(),
              AppPage.import_ => const ImportPage(),
              AppPage.settings => const SettingsPage(),
            },
          ),
      ],
    ),
  ],
);
