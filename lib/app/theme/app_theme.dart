import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'app_colors.dart';

/// 차분한 도구형 + 보라 1색 + Pretendard (설계서 3.2).
ShadThemeData buildAppTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  return ShadThemeData(
    brightness: brightness,
    radius: const BorderRadius.all(Radius.circular(6)),
    textTheme: ShadTextTheme(family: 'Pretendard'),
    colorScheme: ShadColorScheme(
      background: c.background,
      foreground: c.text,
      card: c.surface,
      cardForeground: c.text,
      popover: c.surface,
      popoverForeground: c.text,
      primary: c.accent,
      primaryForeground: const Color(0xffffffff),
      secondary: c.surfaceRaised,
      secondaryForeground: c.text,
      muted: c.surfaceRaised,
      mutedForeground: c.textMuted,
      accent: c.accentSoft,
      accentForeground: c.accentText,
      destructive: c.danger,
      destructiveForeground: const Color(0xffffffff),
      border: c.border,
      input: c.borderStrong,
      ring: c.accent,
      selection: c.accentSoft,
    ),
  );
}
