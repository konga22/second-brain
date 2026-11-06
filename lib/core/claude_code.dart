import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Claude Code 연동: 플러그인 설치와 화면 없는 실행 (설계서 5.2).
///
/// 경로 A라서 우리 서버를 거치지 않는다. 사용자의 Claude Code와 사용자 토큰을 쓴다.
class ClaudeCode {
  ClaudeCode({required this.vault});

  static const marketplaceName = 'second-brain-local';
  static const pluginId = 'second-brain@$marketplaceName';

  final Vault vault;

  String get _home => Platform.environment['HOME'] ?? '.';

  /// 플러그인을 설치하는 곳 (로컬 마켓플레이스 루트).
  String get marketplaceRoot => p.join(
    _home,
    'Library',
    'Application Support',
    Vault.bundleId,
    'claude-code',
  );

  String get pluginDir => p.join(marketplaceRoot, 'second-brain');

  /// 앱은 터미널 PATH를 모르므로 흔한 설치 위치를 차례로 본다.
  Future<String?> findExecutable() async {
    final candidates = [
      p.join(_home, '.local', 'bin', 'claude'),
      '/usr/local/bin/claude',
      '/opt/homebrew/bin/claude',
      p.join(_home, '.claude', 'local', 'claude'),
      p.join(_home, '.npm-global', 'bin', 'claude'),
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    final result = await Process.run('/bin/zsh', ['-lc', 'command -v claude']);
    final found = '${result.stdout}'.trim();
    return result.exitCode == 0 && found.isNotEmpty ? found : null;
  }

  /// 데스크톱 앱 안에서 돌 때 물려받는 Claude Code 변수는 빼고, 흔한 경로를 PATH에 더한다.
  Map<String, String> get _environment {
    final env = {
      for (final e in Platform.environment.entries)
        if (!e.key.startsWith('CLAUDE') && !e.key.startsWith('ANTHROPIC'))
          e.key: e.value,
    };
    env['PATH'] = [
      p.join(_home, '.local', 'bin'),
      '/usr/local/bin',
      '/opt/homebrew/bin',
      env['PATH'] ?? '/usr/bin:/bin:/usr/sbin:/sbin',
    ].join(':');
    return env;
  }

  Future<ProcessResult> _run(String claude, List<String> args, {String? cwd}) =>
      Process.run(
        claude,
        args,
        workingDirectory: cwd,
        environment: _environment,
        includeParentEnvironment: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

  Future<ClaudeCodeStatus> status() async {
    final claude = await findExecutable();
    if (claude == null) return const ClaudeCodeStatus(executable: null);
    final version = await _run(claude, ['--version']);
    final plugins = await _run(claude, ['plugin', 'list', '--json']);
    var installed = false;
    var enabled = false;
    try {
      final json = jsonDecode('${plugins.stdout}');
      final list = json is List
          ? json
          : (json as Map)['plugins'] as List? ?? const [];
      for (final plugin in list.whereType<Map>()) {
        if (plugin['id'] == pluginId || plugin['name'] == pluginId) {
          installed = true;
          enabled = plugin['enabled'] == true;
        }
      }
    } on FormatException {
      installed = false;
    }
    return ClaudeCodeStatus(
      executable: claude,
      version: '${version.stdout}'.trim(),
      isInstalled: installed,
      isEnabled: enabled,
    );
  }

  /// 설치 전에 사용자에게 보여 줄 바뀔 내용.
  List<String> plannedChanges() => [
    '파일 만들기: $marketplaceRoot (플러그인 원본, 스킬 2개, 훅 2개, brain 명령)',
    'Claude Code 설정에 로컬 마켓플레이스 "$marketplaceName" 추가 (claude plugin marketplace add)',
    'Claude Code 플러그인 "$pluginId" 설치 (claude plugin install, 사용자 범위)',
    '지식 폴더 ${vault.root}에 AGENTS.md·CLAUDE.md가 없으면 만들기',
  ];

  /// 플러그인 파일을 쓰고 Claude Code에 등록한다. 반환: 단계별 기록.
  Future<List<String>> install() async {
    final claude = await findExecutable();
    if (claude == null) {
      throw const ClaudeCodeException('Claude Code(claude 명령)를 찾지 못했습니다.');
    }
    final log = <String>[];
    vault.ensure();

    Future<void> copyText(String asset, String target) async {
      final file = File(target)..parent.createSync(recursive: true);
      file.writeAsStringSync(await rootBundle.loadString(asset));
    }

    Future<void> copyBinary(String asset, String target) async {
      final data = await rootBundle.load(asset);
      final file = File(target)..parent.createSync(recursive: true);
      file.writeAsBytesSync(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }

    const source = 'integrations/claude-code';
    await copyText(
      '$source/marketplace.json',
      p.join(marketplaceRoot, '.claude-plugin', 'marketplace.json'),
    );
    await copyText(
      '$source/plugin.json',
      p.join(pluginDir, '.claude-plugin', 'plugin.json'),
    );
    await copyText(
      '$source/hooks.json',
      p.join(pluginDir, 'hooks', 'hooks.json'),
    );
    for (final skill in ['second-brain', 'brain-save']) {
      await copyText(
        '$source/skills/$skill/SKILL.md',
        p.join(pluginDir, 'skills', skill, 'SKILL.md'),
      );
    }
    await copyBinary(
      'assets/brain/bin/brain',
      p.join(pluginDir, 'bin', 'brain'),
    );
    await copyBinary(
      'assets/brain/lib/libsqlite3.dylib',
      p.join(pluginDir, 'lib', 'libsqlite3.dylib'),
    );
    await Process.run('chmod', ['+x', p.join(pluginDir, 'bin', 'brain')]);
    log.add('플러그인 파일 작성: $pluginDir');

    final validate = await _run(claude, [
      'plugin',
      'validate',
      marketplaceRoot,
    ]);
    if (validate.exitCode != 0) {
      throw ClaudeCodeException(
        '플러그인 검사 실패: ${validate.stdout}${validate.stderr}',
      );
    }
    log.add('플러그인 검사 통과');

    final markets = await _run(claude, ['plugin', 'marketplace', 'list']);
    final hasMarket = '${markets.stdout}'.contains(marketplaceName);
    final market = await _run(
      claude,
      hasMarket
          ? ['plugin', 'marketplace', 'update', marketplaceName]
          : ['plugin', 'marketplace', 'add', marketplaceRoot],
    );
    if (market.exitCode != 0) {
      throw ClaudeCodeException('마켓플레이스 등록 실패: ${market.stderr}');
    }
    log.add(hasMarket ? '마켓플레이스 갱신' : '마켓플레이스 추가');

    final installResult = await _run(claude, ['plugin', 'install', pluginId]);
    if (installResult.exitCode != 0) {
      throw ClaudeCodeException('플러그인 설치 실패: ${installResult.stderr}');
    }
    log.add('플러그인 설치: $pluginId');
    return log;
  }

  /// 플러그인 해제. 우리가 넣은 것만 지운다.
  Future<void> uninstall() async {
    final claude = await findExecutable();
    if (claude == null) return;
    await _run(claude, ['plugin', 'uninstall', pluginId]);
    await _run(claude, ['plugin', 'marketplace', 'remove', marketplaceName]);
  }

  /// 사용자의 Claude Code를 화면 없이 실행해 세션 하나를 `brain-save`로 정리한다.
  ///
  /// 허용 도구는 `brain` 명령뿐이고, 지식 폴더에서 돌려 이 실행 자체는 세션 목록에서 빠진다.
  Future<HeadlessResult> saveSession(
    ClaudeSession session, {
    void Function(Process)? onStart,
  }) async {
    final claude = await findExecutable();
    if (claude == null) {
      return const HeadlessResult(ok: false, message: 'Claude Code를 찾지 못했습니다.');
    }
    vault.ensure();
    final process = await Process.start(
      claude,
      [
        '-p',
        'brain-save 스킬을 써서 지난 Claude Code 세션 ${session.shortId} 의 지식을 세컨드 브레인에 초안으로 저장해 줘. '
            '저장할 것이 없으면 brain sessions mark로 skipped 처리해 줘. brain add에는 heredoc을 바로 붙이고 cat 파이프는 쓰지 마. 끝나면 저장한 노트 id와 제목만 짧게 알려 줘.',
        '--permission-mode',
        'dontAsk',
        '--allowedTools',
        'Bash(brain *),Skill(second-brain:brain-save)',
        '--no-session-persistence',
        '--output-format',
        'json',
      ],
      workingDirectory: vault.root,
      environment: _environment,
      includeParentEnvironment: false,
    );
    onStart?.call(process);
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    final stdoutText = await out;
    try {
      final json = jsonDecode(stdoutText) as Map<String, dynamic>;
      final isError = json['is_error'] == true || code != 0;
      return HeadlessResult(
        ok: !isError,
        message: '${json['result'] ?? ''}'.trim(),
        costUsd: (json['total_cost_usd'] as num?)?.toDouble(),
      );
    } on FormatException {
      return HeadlessResult(
        ok: false,
        message: (await err).trim().isEmpty
            ? '실행 실패 (종료 코드 $code)'
            : (await err).trim(),
      );
    }
  }
}

class ClaudeCodeStatus {
  const ClaudeCodeStatus({
    required this.executable,
    this.version = '',
    this.isInstalled = false,
    this.isEnabled = false,
  });

  final String? executable;
  final String version;
  final bool isInstalled;
  final bool isEnabled;

  bool get isFound => executable != null;
}

class HeadlessResult {
  const HeadlessResult({required this.ok, required this.message, this.costUsd});

  final bool ok;
  final String message;
  final double? costUsd;

  /// 로그인이 풀린 경우 (Claude Code가 "Not logged in"이나 401을 돌려줌).
  bool get needsLogin =>
      !ok && (message.contains('Not logged in') || message.contains('/login'));
}

class ClaudeCodeException implements Exception {
  const ClaudeCodeException(this.message);

  final String message;

  @override
  String toString() => message;
}
