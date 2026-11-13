import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'app_colors.dart';

/// 앱 전체 기본 글꼴. ShadTextTheme의 family는 shadcn 글(textTheme.small 등)에만 들어가고, `TextStyle(fontSize: 11)`처럼
/// 글꼴을 적지 않은 글은 앱 기본 글자(ShadApp의 textStyle, 글꼴 없음)를 따라 시스템 글꼴로 나와 한 화면에 글꼴이 섞였다
/// (11/13 화면 검토). 앱 builder에서 [withAppFont]로 깔아 준다.
const appFontFamily = 'Pretendard';

/// [child] 아래 글꼴을 적지 않은 글이 Pretendard로 나오게 한다 (글자 색·크기는 위에서 받은 그대로).
Widget withAppFont(Widget child) => DefaultTextStyle.merge(style: const TextStyle(fontFamily: appFontFamily), child: child);

/// 차분한 도구형 + 보라 1색 + Pretendard (설계서 3.2).
ShadThemeData buildAppTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  return ShadThemeData(
    brightness: brightness,
    radius: const BorderRadius.all(Radius.circular(6)),
    textTheme: ShadTextTheme(family: appFontFamily),
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
