import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_config_provider.dart';

/// 화면 전체 배율 (⌘+ / ⌘- / ⌘0). 대화상자까지 함께 커지도록 앱 맨 바깥에서 감싼다.
/// 레이아웃은 (창 크기 / 배율)로 하고 그린 뒤 배율만큼 키운다.
class ZoomScope extends ConsumerWidget {
  const ZoomScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(appConfigProvider.select((c) => c.uiScale));
    if (scale == 1) return child;
    final media = MediaQuery.of(context);
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
          child: MediaQuery(data: media.copyWith(size: size), child: child),
        ),
      ),
    );
  }
}
