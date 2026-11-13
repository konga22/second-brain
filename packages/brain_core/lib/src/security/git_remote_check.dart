import 'dart:io';

import 'package:path/path.dart' as p;

import 'secret_mask.dart';

/// 지식 폴더를 감싼 git 저장소에 붙은 원격 하나. [url]은 자격 증명을 가린 주소다.
class GitRemote {
  const GitRemote(this.name, this.url);

  final String name;
  final String url;

  String get host => remoteHost(url);
}

/// 지식 폴더가 원격이 붙은 git 저장소 안에 있다는 점검 결과 (설계서_프롬프트이후 4.6).
class GitRemoteExposure {
  const GitRemoteExposure({required this.repoRoot, required this.remotes});

  final String repoRoot;
  final List<GitRemote> remotes;

  /// doctor·앱 연동 화면이 같은 문장을 쓴다.
  String get warning {
    final names = [for (final r in remotes) '${r.name} → ${r.host}'].join(', ');
    final first = remotes.first.name;
    return '지식 폴더가 원격($names)이 붙은 git 폴더 $repoRoot 안에 있다. '
        '노트는 AI에 자동으로 들어가는 개인 지식이라 push하면 함께 올라간다 — '
        '지식 폴더를 git 폴더 밖으로 옮기거나, 원격을 지우거나(git remote remove $first), .gitignore에 넣기';
  }
}

/// [vaultRoot]가 원격이 붙은 git 작업 폴더 안에 있으면 그 저장소와 원격을 돌려준다. 아니면 null.
///
/// git이 없는 맥도 있고 doctor는 빨라야 해서 `.git`과 `config`를 직접 읽는다.
/// 원격이 있을 때만 git을 불러 `.gitignore`로 빠졌는지 본다 (설계서_프롬프트이후 4.6).
/// 다루지 않는 것: `GIT_DIR` 같은 환경 변수, config의 `[include]`, 전역 config의 원격.
GitRemoteExposure? findGitRemoteExposure(String vaultRoot) {
  final vault = _canonical(vaultRoot);
  for (var dir = vault; ; dir = p.dirname(dir)) {
    final gitDir = _gitDirOf(dir);
    // config가 없는 `.git`(만들다 만 저장소)에서 멈추면 바깥 저장소의 원격을 못 봤다 (11/13 검토)
    if (gitDir != null && (File(p.join(gitDir, 'config')).existsSync() || File(p.join(gitDir, 'commondir')).existsSync())) {
      final remotes = _remotesOf(gitDir);
      if (remotes.isEmpty || _isIgnored(dir, vault)) return null;
      return GitRemoteExposure(repoRoot: dir, remotes: remotes);
    }
    if (p.dirname(dir) == dir) return null;
  }
}

/// 주소에서 사용자·토큰을 가린다. `git@host:경로`(ssh) 형식은 비밀이 아니라 그대로 둔다.
String maskRemoteUrl(String url) {
  // 사용자 정보는 호스트 앞 마지막 `@`까지다: 비밀번호에 `@`가 있으면 첫 `@`에서 끊겨 뒷부분이 보였다 (11/13 검토).
  final masked = url.replaceFirstMapped(RegExp(r'^([a-z][a-z0-9+.\-]*://)([^/]+)@', caseSensitive: false), (m) {
    final isSshUser = m[1]!.toLowerCase().contains('ssh') && !m[2]!.contains(':');
    return isSshUser ? m[0]! : '${m[1]}[가림]@';
  });
  return maskSecrets(masked);
}

/// 원격 주소의 호스트. 로컬 폴더를 원격으로 둔 경우는 '로컬 경로'.
String remoteHost(String url) {
  final scheme = RegExp(r'^([a-z][a-z0-9+.\-]*)://(?:[^/]*@)?([^/:]*)', caseSensitive: false).firstMatch(url);
  if (scheme != null) {
    return scheme[1]!.toLowerCase() == 'file' || scheme[2]!.isEmpty ? '로컬 경로' : scheme[2]!;
  }
  // scp 형식 `사용자@호스트:경로`. 첫 ':' 앞에 '/'가 있으면 로컬 경로다.
  final scp = RegExp(r'^(?:[^@/:]+@)?([^/:]+):').firstMatch(url);
  return scp != null ? scp[1]! : '로컬 경로';
}

String _canonical(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    return Directory(absolute).resolveSymbolicLinksSync();
  } on FileSystemException {
    return absolute;
  }
}

/// [dir]/.git이 폴더면 그대로, 파일(worktree·submodule)이면 `gitdir:`이 가리키는 곳.
String? _gitDirOf(String dir) {
  final dotGit = p.join(dir, '.git');
  if (FileSystemEntity.isDirectorySync(dotGit)) return dotGit;
  final file = File(dotGit);
  if (!file.existsSync()) return null;
  try {
    final line = file.readAsLinesSync().firstWhere((l) => l.startsWith('gitdir:'), orElse: () => '');
    if (line.isEmpty) return null;
    return p.normalize(p.join(dir, line.substring('gitdir:'.length).trim()));
  } on FileSystemException {
    return null;
  }
}

/// 저장소 config의 `[remote "이름"]`들. worktree는 `commondir`이 가리키는 공용 config에 원격이 있다.
List<GitRemote> _remotesOf(String gitDir) {
  final dirs = [gitDir];
  final commonDir = File(p.join(gitDir, 'commondir'));
  if (commonDir.existsSync()) {
    try {
      dirs.add(p.normalize(p.join(gitDir, commonDir.readAsStringSync().trim())));
    } on FileSystemException {
      // 공용 폴더를 못 읽으면 worktree 쪽 config만 본다.
    }
  }
  final found = <String, String>{};
  for (final dir in dirs) {
    for (final name in ['config', 'config.worktree']) {
      final file = File(p.join(dir, name));
      if (!file.existsSync()) continue;
      try {
        _parseRemotes(file.readAsLinesSync(), found);
      } on FileSystemException {
        continue;
      }
    }
  }
  return [for (final e in found.entries) GitRemote(e.key, maskRemoteUrl(e.value))];
}

final _remoteHeader = RegExp(r'^\s*\[\s*remote(?:\s+"((?:[^"\\]|\\.)*)"|\.([^\]\s]+))\s*\](.*)$', caseSensitive: false);
final _otherHeader = RegExp(r'^\s*\[');
final _urlKey = RegExp(r'^\s*url\s*=\s*(.*)$', caseSensitive: false);

/// 원격 이름 → 주소. 주소 줄이 없는 원격 구역도 원격으로 센다.
void _parseRemotes(List<String> lines, Map<String, String> found) {
  String? current;
  for (final raw in lines) {
    var line = raw;
    final header = _remoteHeader.firstMatch(line);
    if (header != null) {
      current = header[1] ?? header[2];
      found.putIfAbsent(current!, () => '');
      line = header[3]!;
    } else if (_otherHeader.hasMatch(line)) {
      current = null;
      continue;
    }
    if (current == null) continue;
    final url = _urlKey.firstMatch(line);
    if (url != null && found[current]!.isEmpty) found[current] = _configValue(url[1]!);
  }
}

/// 따옴표와 줄 끝 주석(`#`, `;`)을 걷어 낸다.
String _configValue(String raw) {
  final out = StringBuffer();
  var quoted = false;
  for (var i = 0; i < raw.length; i++) {
    final c = raw[i];
    if (c == '"') {
      quoted = !quoted;
    } else if (!quoted && (c == '#' || c == ';')) {
      break;
    } else if (c == '\\' && i + 1 < raw.length) {
      out.write(raw[++i]);
    } else {
      out.write(c);
    }
  }
  return out.toString().trim();
}

/// 지식 폴더가 `.gitignore`로 빠졌고 이미 올린(추적 중인) 파일도 없으면 true.
/// 원격이 있을 때만 부르고, git이 없거나 실패하면 false(경고를 남긴다).
bool _isIgnored(String repoRoot, String vault) {
  if (vault == repoRoot) return false;
  final rel = p.relative(vault, from: repoRoot);
  // 개발자 도구가 없는 맥의 /usr/bin/git은 설치 창을 띄운다 — 그때는 부르지 않고 경고를 남긴다 (11/13 검토).
  if (Platform.isMacOS && !_hasDeveloperTools()) return false;
  // GIT_DIR·GIT_WORK_TREE가 물려오면(git 훅 안에서 doctor 실행 등) 다른 저장소를 본다 → GIT_로 시작하는 값은 빼고 부른다.
  final env = {for (final e in Platform.environment.entries) if (!e.key.startsWith('GIT_')) e.key: e.value};
  ProcessResult git(List<String> args) =>
      Process.runSync('git', ['-C', repoRoot, ...args], environment: env, includeParentEnvironment: false);
  try {
    final ignored = git(['check-ignore', '-q', '--', rel]);
    if (ignored.exitCode != 0) return false;
    final tracked = git(['ls-files', '--', rel]);
    return tracked.exitCode == 0 && (tracked.stdout as String).trim().isEmpty;
  } on ProcessException {
    return false;
  }
}

/// `xcode-select -p`는 개발자 도구가 없어도 창을 띄우지 않고 실패만 한다.
bool _hasDeveloperTools() {
  try {
    return Process.runSync('xcode-select', ['-p']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
