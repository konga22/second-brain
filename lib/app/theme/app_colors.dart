import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 설계서 3.2의 색 토큰. 값은 시안 v8(`docs/시안/20261106-second-brain-ui-v8`)과 같다.
class AppColors {
  const AppColors._({
    required this.background,
    required this.sidebar,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.accent,
    required this.accentText,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.danger,
  });

  final Color background;
  final Color sidebar;
  final Color surface;
  final Color surfaceRaised;
  final Color border;
  final Color borderStrong;
  final Color text;
  final Color textMuted;
  final Color textFaint;
  final Color accent;
  final Color accentText;
  final Color accentSoft;
  final Color success;
  final Color warning;
  final Color danger;

  static const light = AppColors._(
    background: Color(0xfff7f7f8),
    sidebar: Color(0xfff0f0f2),
    surface: Color(0xffffffff),
    surfaceRaised: Color(0xfff4f4f6),
    border: Color(0xffe4e4e7),
    borderStrong: Color(0xffd4d4d8),
    text: Color(0xff18181b),
    textMuted: Color(0xff52525b),
    textFaint: Color(0xffa1a1aa),
    accent: Color(0xff7c3aed),
    accentText: Color(0xff6d28d9),
    accentSoft: Color(0x1a7c3aed),
    success: Color(0xff16a34a),
    warning: Color(0xffd97706),
    danger: Color(0xffdc2626),
  );

  static const dark = AppColors._(
    background: Color(0xff0e0e11),
    sidebar: Color(0xff111114),
    surface: Color(0xff151519),
    surfaceRaised: Color(0xff1b1b20),
    border: Color(0xff25252c),
    borderStrong: Color(0xff34343c),
    text: Color(0xffededf0),
    textMuted: Color(0xffa1a1aa),
    textFaint: Color(0xff6b6b75),
    accent: Color(0xff8b5cf6),
    accentText: Color(0xffb39dfb),
    accentSoft: Color(0x298b5cf6),
    success: Color(0xff22c55e),
    warning: Color(0xfff59e0b),
    danger: Color(0xffef4444),
  );

  /// 그래프 영역은 라이트 테마에서도 어둡게 둔다 (설계서 3.2).
  static const graphTop = Color(0xff171428);
  static const graphBottom = Color(0xff0b0a12);
  static const graphNode = Color(0xffd6d3e8);
  static const graphLabel = Color(0x8cd6d3e8);
  static const graphAccent = Color(0xffa78bfa);

  static AppColors of(BuildContext context) =>
      ShadTheme.of(context).brightness == Brightness.dark ? dark : light;
}
