import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_config_provider.dart';

/// 화면 전체 배율 (⌘+ / ⌘- / ⌘0). 대화상자까지 함께 커지도록 앱 맨 바깥에서 감싼다.
/// 레이아웃은 (창 크기 / 배율)로 하고 그린 뒤 배율만큼 키운다.
///
/// 배율은 한 번에 뛰지 않고 [duration] 동안 부드럽게 바뀐다 (11/07 "덜덜 떨림" 의견).
/// 배율이 1이어도 감싸는 위젯 구조를 그대로 둔다: 구조가 바뀌면 그 아래 화면이 새로 만들어져
/// 그래프 위치·스크롤 같은 상태를 잃고 다시 맞추면서 튄다.
class ZoomScope extends ConsumerWidget {
  const ZoomScope({super.key, required this.child});

  /// 배율을 키워도 지켜 주는 최소 논리 폭.
  static const minLogicalWidth = 1000.0;
  static const duration = Duration(milliseconds: 180);

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wanted = ref.watch(appConfigProvider.select((c) => c.uiScale));
    final media = MediaQuery.of(context);
    // 키워도 화면 논리 폭이 [minLogicalWidth]보다 좁아지지 않게 실제 배율을 제한한다.
    // 그보다 좁으면 사이드바·노트 패널 사이 가운데가 너무 좁아 화면이 넘친다 (11/07 L-0005).
    final limit = media.size.width / minLogicalWidth;
    final target = wanted > 1 && wanted > limit
        ? (limit < 1 ? 1.0 : limit)
        : wanted;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: target),
      duration: duration,
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, scale, child) {
        final size = media.size / scale;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: size.width,
            maxWidth: size.width,
            minHeight: size.height,
            maxHeight: size.height,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: MediaQuery(
                data: media.copyWith(size: size),
                child: child!,
              ),
            ),
          ),
        );
      },
    );
  }
}
