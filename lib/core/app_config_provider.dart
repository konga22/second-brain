import 'package:brain_core/brain_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 기기 설정(화면 배율·패널 너비 등). `config.json`에 저장하고 CLI도 같은 파일을 읽는다.
final appConfigProvider = NotifierProvider<AppConfigNotifier, AppConfig>(
  AppConfigNotifier.new,
);

class AppConfigNotifier extends Notifier<AppConfig> {
  static const minScale = 0.7;
  static const maxScale = 1.6;

  @override
  AppConfig build() => AppConfig.load();

  void update(AppConfig Function(AppConfig) change, {bool save = true}) {
    state = change(state);
    if (save) state.save();
  }

  /// ⌘+ / ⌘- : 0.1씩, ⌘0 : 원래대로.
  void zoom(int step) => update(
    (c) => c.copyWith(
      uiScale: step == 0
          ? 1
          : ((c.uiScale + step * 0.1).clamp(minScale, maxScale) * 10).round() / 10,
    ),
  );
}
