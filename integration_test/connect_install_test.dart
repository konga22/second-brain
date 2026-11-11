import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:secondbrain/app/router/app_page.dart';
import 'package:secondbrain/app/second_brain_app.dart';
import 'package:secondbrain/core/brain_providers.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 연동 화면의 [연동]·[다시 설치]를 실제로 눌러, 앱에 묶인 brain이 그대로 플러그인에 깔리는지 본다.
/// (11/11 기능검토 K-22: 앱에 옛 brain이 묶여 [연동]이 플러그인을 옛 판으로 내렸다. K-17: 깔린 brain의 훅 판정.)
///
/// 이 시험은 이 맥의 실제 Claude Code 플러그인을 다시 설치한다. 그래서 ALLOW_REAL_INSTALL=1을 줄 때만 돈다.
/// 지식 폴더와 설정은 실제 것을 쓰지 않게 사본·임시 파일을 준다.
///
/// bash tool/build_brain.sh
/// BRAIN_VAULT=<임시 폴더> BRAIN_CONFIG=<임시 파일> ALLOW_REAL_INSTALL=1 \
///   flutter test integration_test/connect_install_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
    for (var i = 0; i < ms ~/ 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }
  }

  /// 깔린 brain의 PreToolUse 훅에 명령을 넣고 판정(없으면 빈 문자열)을 받는다. 훅은 명령을 실행하지 않는다.
  Future<String> hookDecision(String brain, String command) async {
    final process = await Process.start(brain, ['hook', 'pre-tool']);
    process.stdin.write(jsonEncode({
      'tool_name': 'Bash',
      'tool_input': {'command': command},
    }));
    await process.stdin.close();
    final out = await process.stdout.transform(utf8.decoder).join();
    await process.exitCode;
    return out.trim();
  }

  testWidgets('[연동]을 누르면 앱에 묶인 brain이 플러그인에 깔린다', (tester) async {
    final env = Platform.environment;
    expect(env['BRAIN_VAULT'] ?? '', isNotEmpty, reason: '실제 지식 폴더 보호: BRAIN_VAULT에 임시 폴더를 주세요');
    expect(env['BRAIN_CONFIG'] ?? '', isNotEmpty, reason: '실제 설정 보호: BRAIN_CONFIG에 임시 파일을 주세요');
    expect(env['ALLOW_REAL_INSTALL'], '1', reason: '이 시험은 실제 Claude Code 플러그인을 다시 설치합니다. ALLOW_REAL_INSTALL=1을 주세요');

    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    await tester.pumpWidget(const ProviderScope(child: SecondBrainApp()));
    await settle(tester, 3000);
    final container = ProviderScope.containerOf(tester.element(find.byType(SecondBrainApp)));
    final claude = container.read(claudeCodeProvider);
    GoRouter.of(tester.element(find.byType(Navigator).first)).go(AppPage.connect.path);
    await settle(tester, 3000);

    // 상태에 따라 버튼 이름이 [연동] 또는 [다시 설치]다. 화면 제목·메뉴의 '연동' 글자와 헷갈리지 않게 버튼만 찾는다.
    final reinstall = find.widgetWithText(ShadButton, '다시 설치');
    final install = find.widgetWithText(ShadButton, '연동');
    final button = reinstall.evaluate().isNotEmpty ? reinstall : install;
    expect(button, findsOneWidget, reason: '연동 화면에 설치 버튼이 보여야 한다 (Claude Code를 찾지 못하면 안 보인다)');
    await tester.tap(button);
    await settle(tester, 1000);

    // 바뀔 내용을 보여 주는 확인 창 → [연동]
    final confirm = find.descendant(of: find.byType(ShadDialog), matching: find.widgetWithText(ShadButton, '연동'));
    expect(confirm, findsOneWidget, reason: '설치 전에 바뀔 내용을 보여 주는 확인 창이 떠야 한다');
    await tester.tap(confirm);

    // claude plugin 명령이 끝날 때까지 기다린다 (최대 90초).
    final done = find.textContaining('플러그인 설치:');
    final failed = find.textContaining('실패');
    for (var i = 0; i < 450 && done.evaluate().isEmpty && failed.evaluate().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }
    expect(failed, findsNothing, reason: '설치가 실패했다');
    expect(done, findsOneWidget, reason: '90초 안에 설치가 끝나지 않았다');

    // 빈 통과가 아니게: 방금 깔린 파일이 앱에 묶인 자산과 바이트까지 같은지 본다.
    final installed = File(p.join(claude.pluginDir, 'bin', 'brain'));
    final bundled = await rootBundle.load('assets/brain/bin/brain');
    expect(installed.existsSync(), isTrue);
    expect(
      installed.readAsBytesSync(),
      bundled.buffer.asUint8List(bundled.offsetInBytes, bundled.lengthInBytes),
      reason: '플러그인에 깔린 brain이 앱에 묶인 것과 다르다',
    );
    expect(
      File(p.join(claude.pluginDir, 'hooks', 'hooks.json')).readAsStringSync(),
      await rootBundle.loadString('integrations/claude-code/hooks.json'),
    );

    // 깔린 brain이 실행되고, 훅이 정상 입력은 떼어 허락하고 우회 입력은 손대지 않는다 (K-17).
    final ok = await hookDecision(installed.path, 'brain show n_0042 2>&1 | head -60');
    expect(ok, contains('"permissionDecision":"allow"'));
    expect(ok, contains('"command":"brain show n_0042"'));
    expect(await hookDecision(installed.path, 'brain find x & touch /tmp/sb_probe | head'), isEmpty);
    expect(await hookDecision(installed.path, 'brain lesson "add" --trigger a --action b --reason c 2>&1'), isEmpty);
  });
}
