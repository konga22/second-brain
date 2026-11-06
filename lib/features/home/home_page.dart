import 'package:flutter/widgets.dart';

import '../../app/theme/app_colors.dart';

/// 홈 그래프 자리. 그래프는 3주차에 그린다 (설계서 5.5).
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const RadialGradient(
          radius: 1.2,
          colors: [AppColors.graphTop, AppColors.graphBottom],
        ),
      ),
      alignment: Alignment.center,
      child: const Text(
        '아직 노트가 없습니다',
        style: TextStyle(color: AppColors.graphLabel, fontSize: 13),
      ),
    );
  }
}
