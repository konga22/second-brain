import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/app_config_provider.dart';
import '../../core/brain_providers.dart';
import '../connect/auto_tidy.dart';

/// 설정 (설계서 3절 `/settings`, 4.1, 5.7): 지식 폴더 위치·Finder 열기, 백업·복원, 온보딩 요약.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  // 설정은 한 저장소(appConfigProvider)로만 읽고 쓴다. 따로 읽으면 패널 너비·배율을 옛값으로 덮어쓴다.
  AppConfig get _config => ref.read(appConfigProvider);
  String? _message;
  bool _isWorking = false;
  Future<List<ClaudeSession>>? _preview;

  static const backupRemindDays = 7;

  void _save(AppConfig config) {
    ref.read(appConfigProvider.notifier).update((_) => config);
    setState(() {});
  }

  Future<void> _onAutoTidy(bool isOn) async {
    if (isOn) {
      final isConfirmed = await showShadDialog<bool>(
        context: context,
        builder: (context) => ShadDialog(
          title: const Text('자동 정리를 켤까요?'),
          description: Text(
            '대화 중 자동 저장에서 빠진 세션을 앱이 6시간마다 정리합니다. 사용자의 Claude Code 사용량을 쓰며, '
            '하루 ${_config.autoTidyDailyUsd.toStringAsFixed(1)}달러에 닿으면 멈춥니다. 긴 세션(대화 150개 넘음)은 건너뜁니다.',
          ),
          actions: [
            ShadButton.outline(onPressed: () => Navigator.of(context).pop(false), child: const Text('취소')),
            ShadButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('켜기')),
          ],
        ),
      );
      if (isConfirmed != true) return;
    }
    _save(_config.copyWith(isAutoTidyOn: isOn));
  }

  /// iCloud 동기화 폴더는 파일이 기기에 없을 수 있어 경고한다 (설계서 4.1).
  String? _cloudWarning(String path) {
    final home = Platform.environment['HOME'] ?? '';
    if (path.contains('Mobile Documents') || path.contains('CloudStorage')) {
      return '클라우드 동기화 폴더입니다. 파일이 이 맥에 내려와 있지 않으면 검색·연동이 실패할 수 있습니다.';
    }
    if (p.isWithin(p.join(home, 'Documents'), path) || p.isWithin(p.join(home, 'Desktop'), path)) {
      return '문서·데스크탑 폴더는 iCloud 동기화가 켜져 있으면 파일이 기기에 없을 수 있습니다.';
    }
    return null;
  }

  Future<void> _onChangeVault() async {
    final dir = await getDirectoryPath(confirmButtonText: '이 폴더 쓰기');
    if (dir == null) return;
    _save(_config.copyWith(vaultPath: dir));
    ref.invalidate(vaultProvider);
    ref.read(selectedNoteProvider.notifier).select(null);
    setState(() => _message = '지식 폴더를 바꿨습니다: $dir (brain 명령도 같은 폴더를 씁니다)');
  }

  Future<void> _onBackup() async {
    final vault = ref.read(vaultProvider);
    final date = formatTime(DateTime.now()).substring(0, 10);
    final location = await getSaveLocation(suggestedName: 'SecondBrain-$date.zip');
    if (location == null) return;
    setState(() {
      _isWorking = true;
      _message = '백업 중…';
    });
    // macOS 기본 도구 ditto로 폴더째 압축한다. 색인은 지식 폴더 밖(캐시)에 있어 저절로 빠진다.
    final result = await Process.run('ditto', [
      '-c', '-k', '--sequesterRsrc', '--keepParent', vault.root, location.path,
    ]);
    setState(() => _isWorking = false);
    if (result.exitCode != 0) {
      setState(() => _message = '백업 실패: ${result.stderr}');
      return;
    }
    _save(_config.copyWith(lastBackupAt: DateTime.now()));
    final size = File(location.path).lengthSync() / 1024 / 1024;
    setState(() => _message = '백업함: ${location.path} (${size.toStringAsFixed(1)}MB)');
  }

  Future<void> _onRestore() async {
    final zip = await openFile(
      acceptedTypeGroups: const [XTypeGroup(label: '백업', extensions: ['zip'])],
    );
    if (zip == null) return;
    final target = await getDirectoryPath(confirmButtonText: '여기에 풀기');
    if (target == null) return;
    setState(() {
      _isWorking = true;
      _message = '복원 중…';
    });
    final result = await Process.run('ditto', ['-x', '-k', zip.path, target]);
    setState(() => _isWorking = false);
    if (result.exitCode != 0) {
      setState(() => _message = '복원 실패: ${result.stderr}');
      return;
    }
    final restored = Directory(target)
        .listSync()
        .whereType<Directory>()
        .where((d) => File(p.join(d.path, 'AGENTS.md')).existsSync())
        .map((d) => d.path)
        .firstOrNull;
    setState(
      () => _message = restored == null
          ? '풀었습니다: $target (지식 폴더를 찾지 못했습니다. [폴더 바꾸기]로 직접 고르세요.)'
          : '풀었습니다: $restored — 이 폴더를 쓰려면 [폴더 바꾸기]에서 고르세요.',
    );
  }

  /// 자동으로 지식 넣기: 대화 중 자동 저장 + 자동 정리(안전망).
  Widget _autoCard(BuildContext context) {
    final theme = ShadTheme.of(context);
    final config = ref.watch(appConfigProvider);
    final tidy = ref.watch(autoTidyProvider);
    final spent = ref.read(autoTidyProvider.notifier).spentToday(config);
    return ShadCard(
      title: const Text('자동으로 지식 넣기'),
      description: const Text(
        '대화를 하다 결정·문제 해결·작업 규칙 같은 지식이 생기면 묻지 않고 정리 대기에 초안으로 넣습니다. 확인은 노트·정리 보드에서 합니다.',
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ShadSwitch(
                  value: !config.isAutoCaptureOff,
                  onChanged: (on) => _save(config.copyWith(isAutoCaptureOff: !on)),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('대화 중 자동 저장 — Claude Code 세션마다 그 자리에서 저장 (새 세션부터 적용, 노트 하나에 출력 몇백 토큰)'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                ShadSwitch(value: config.isAutoTidyOn, onChanged: _onAutoTidy),
                const SizedBox(width: 10),
                const Expanded(child: Text('자동 정리 — 그래도 빠진 세션을 앱이 6시간마다 정리 (안전망)')),
              ],
            ),
            if (config.isAutoTidyOn) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('하루 상한', style: theme.textTheme.muted),
                  const SizedBox(width: 8),
                  for (final usd in const [0.5, 1.0, 3.0])
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: (config.autoTidyDailyUsd == usd ? ShadButton.secondary : ShadButton.ghost)(
                        size: ShadButtonSize.sm,
                        height: 26,
                        onPressed: () => _save(config.copyWith(autoTidyDailyUsd: usd)),
                        child: Text('${usd.toStringAsFixed(1)}달러'),
                      ),
                    ),
                  const SizedBox(width: 8),
                  Text('오늘 ${spent.toStringAsFixed(2)}달러 씀', style: theme.textTheme.muted),
                  ShadButton.outline(
                    size: ShadButtonSize.sm,
                    enabled: !tidy.isRunning,
                    onPressed: () => ref.read(autoTidyProvider.notifier).run(),
                    child: Text(tidy.isRunning ? '정리 중…' : '지금 정리'),
                  ),
                ],
              ),
              FutureBuilder(
                future: _preview ??= ref.read(autoTidyProvider.notifier).preview(),
                builder: (context, snap) => Text(
                  snap.hasError
                      ? '정리 대상을 읽지 못했습니다: ${snap.error}'
                      : (snap.hasData ? '지금 정리 대상 ${snap.data!.length}개 (끝난 세션 중 저장 안 한 것, 긴 세션 제외)' : '정리 대상 세는 중…'),
                  style: theme.textTheme.muted.copyWith(fontSize: 12),
                ),
              ),
              if (tidy.isRunning) Text(tidy.step, style: theme.textTheme.muted),
              for (final line in tidy.log.take(6)) Text(line, style: theme.textTheme.muted.copyWith(fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    ref.watch(appConfigProvider);
    final colors = AppColors.of(context);
    final vault = ref.watch(vaultProvider);
    final warning = _cloudWarning(vault.root);
    final lastBackup = _config.lastBackupAt;
    final backupDays = lastBackup == null ? null : DateTime.now().difference(lastBackup).inDays;
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
      children: [
        Text('설정', style: theme.textTheme.h4),
        const SizedBox(height: 16),
        ShadCard(
          title: const Text('지식 폴더'),
          description: const Text(
            '노트·실수 노트·할 일은 이 폴더의 md 파일에만 저장되고 서버로 보내지 않습니다. 앱·brain 명령·사용자 AI가 같은 폴더를 씁니다.',
          ),
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(vault.root, style: theme.textTheme.small),
                if (warning != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(warning, style: TextStyle(color: colors.warning, fontSize: 12)),
                  ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    ShadButton.outline(
                      size: ShadButtonSize.sm,
                      leading: const Icon(LucideIcons.folderOpen, size: 14),
                      onPressed: () => Process.run('open', [vault.root]),
                      child: const Text('Finder에서 열기'),
                    ),
                    const SizedBox(width: 8),
                    ShadButton.outline(size: ShadButtonSize.sm, onPressed: _onChangeVault, child: const Text('폴더 바꾸기')),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ShadCard(
          title: const Text('백업·복원'),
          description: const Text('지식 폴더를 폴더째 zip으로 내보냅니다. 색인은 다시 만들 수 있어 넣지 않습니다.'),
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lastBackup == null
                      ? '아직 백업하지 않았습니다.'
                      : '마지막 백업: ${formatTime(lastBackup).substring(0, 16).replaceFirst('T', ' ')} ($backupDays일 전)',
                  style: TextStyle(
                    fontSize: 13,
                    color: (backupDays ?? backupRemindDays) >= backupRemindDays ? colors.warning : colors.textMuted,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    ShadButton(size: ShadButtonSize.sm, enabled: !_isWorking, onPressed: _onBackup, child: const Text('백업 만들기')),
                    const SizedBox(width: 8),
                    ShadButton.outline(size: ShadButtonSize.sm, enabled: !_isWorking, onPressed: _onRestore, child: const Text('백업에서 복원')),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ShadCard(
          title: const Text('Claude Code 온보딩 요약'),
          description: const Text('새 세션을 시작할 때 주요 주제와 자주 받은 교정(150토큰 이하)을 넣습니다.'),
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                ShadSwitch(
                  value: !_config.isOnboardingOff,
                  onChanged: (on) => _save(_config.copyWith(isOnboardingOff: !on)),
                ),
                const SizedBox(width: 10),
                Text(_config.isOnboardingOff ? '끔' : '켬'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _autoCard(context),
        if (_message != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message!, style: theme.textTheme.muted)),
      ],
    );
  }
}
