import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'board_view.dart';
import 'graph_view.dart';
import 'structure_list_view.dart';
import 'timeline_view.dart';

/// 홈 (설계서 3.3): 같은 지식을 보는 네 가지 방식 [그래프 | 목록 | 타임라인 | 정리 보드].
enum HomeMode {
  graph('그래프', LucideIcons.network),
  list('목록', LucideIcons.listTree),
  timeline('타임라인', LucideIcons.history),
  board('정리 보드', LucideIcons.kanban);

  const HomeMode(this.label, this.icon);

  final String label;
  final IconData icon;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  HomeMode _mode = HomeMode.graph;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 32, 16, 10),
          child: Row(
            children: [
              for (final mode in HomeMode.values)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: mode == _mode
                      ? ShadButton.secondary(
                          size: ShadButtonSize.sm,
                          leading: Icon(mode.icon, size: 14),
                          onPressed: () {},
                          child: Text(mode.label),
                        )
                      : ShadButton.ghost(
                          size: ShadButtonSize.sm,
                          leading: Icon(mode.icon, size: 14),
                          onPressed: () => setState(() => _mode = mode),
                          child: Text(mode.label),
                        ),
                ),
              const Spacer(),
              Text('⌘K 찾기 · ⌘N 새 노트', style: ShadTheme.of(context).textTheme.muted),
            ],
          ),
        ),
        Expanded(
          child: switch (_mode) {
            HomeMode.graph => const GraphView(),
            HomeMode.list => const StructureListView(),
            HomeMode.timeline => const TimelineView(),
            HomeMode.board => const BoardView(),
          },
        ),
      ],
    );
  }
}
