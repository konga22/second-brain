import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 사이드바 화면 목록 (설계서 3절). 경로와 이름은 여기에만 둔다.
enum AppPage {
  home('/', '홈', LucideIcons.house),
  notes('/notes', '노트', LucideIcons.fileText),
  chat('/chat', 'AI 질문', LucideIcons.messageSquare),
  lessons('/lessons', '배운 것', LucideIcons.lightbulb),
  todos('/todos', '할 일', LucideIcons.squareCheck),
  import_('/import', '가져오기', LucideIcons.fileInput),
  connect('/connect', '연동', LucideIcons.plug),
  pricing('/pricing', '요금제', LucideIcons.creditCard),
  settings('/settings', '설정', LucideIcons.settings);

  const AppPage(this.path, this.label, this.icon);

  final String path;
  final String label;
  final IconData icon;

  static AppPage fromPath(String path) => values.firstWhere(
    (page) => page.path == path,
    orElse: () => AppPage.home,
  );
}
