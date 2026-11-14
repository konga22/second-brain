import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../shared/vault_gate.dart';
import '../shared/zoom_scope.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';

class SecondBrainApp extends StatelessWidget {
  const SecondBrainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ShadApp.router(
      title: '세컨드 브레인',
      routerConfig: appRouter,
      themeMode: ThemeMode.system,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      locale: const Locale('ko', 'KR'),
      supportedLocales: const [Locale('ko', 'KR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // 지식 폴더가 준비되기 전에는 앱 화면(라우터)을 그리지 않는다 (11/11 K-33).
      // 글꼴을 적지 않은 글도 Pretendard로 (shadcn 글과 섞이지 않게)
      builder: (context, child) => withAppFont(ZoomScope(child: VaultGate(child: child ?? const SizedBox()))),
    );
  }
}
