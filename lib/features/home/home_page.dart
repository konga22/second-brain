import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'board_view.dart';
import 'first_run_card.dart';
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
        // E3 첫 실행 3단계 안내 (닫으면 다시 안 보임)
        const FirstRunCard(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 32, 16, 10),
          // 좁은 창·큰 화면 배율에서도 넘치지 않게: 보기 버튼은 가로로 밀어 보고, 단축키 안내는 자리가 없으면 줄인다.
          child: Row(
            children: [
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
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
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  '⌘K 찾기 · ⌘N 새 노트',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: ShadTheme.of(context).textTheme.muted,
                ),
              ),
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
