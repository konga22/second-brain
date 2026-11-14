import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 지식 폴더가 원격이 붙은 git 폴더 안에 있으면 경고한다 (설계서_프롬프트이후 4.6).
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('git_remote_'));
  tearDown(() => temp.deleteSync(recursive: true));

  String mkdir(String rel) => (Directory(p.join(temp.path, rel))..createSync(recursive: true)).path;

  group('파일만 읽어 판단한다 (git 없이)', () {
    test('git 폴더가 아니면 조용하다', () {
      expect(findGitRemoteExposure(mkdir('vault')), isNull);
    });

    test('원격 없는 .git/config면 조용하다', () {
      mkdir('repo/.git');
      File(p.join(temp.path, 'repo/.git/config')).writeAsStringSync('[core]\n\tbare = false\n');
      expect(findGitRemoteExposure(mkdir('repo/vault')), isNull);
    });

    test('원격이 있으면 이름과 호스트를 알려 준다', () {
      mkdir('repo/.git');
      File(p.join(temp.path, 'repo/.git/config')).writeAsStringSync(
        '[core]\n\tbare = false\n[remote "origin"]\n\turl = git@github.com:x/y.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n',
      );
      final found = findGitRemoteExposure(mkdir('repo/a/vault'))!;
      expect(found.repoRoot, _real(p.join(temp.path, 'repo')));
      expect(found.remotes.single.name, 'origin');
      expect(found.remotes.single.host, 'github.com');
      expect(found.warning, contains('origin'));
      expect(found.warning, contains('github.com'));
    });

    test('.git 파일(gitdir:)이 가리키는 곳의 config를 읽는다', () {
      mkdir('real/.git');
      File(p.join(temp.path, 'real/.git/config')).writeAsStringSync('[remote "up"]\n  url = https://gitlab.com/a/b.git\n');
      mkdir('repo');
      File(p.join(temp.path, 'repo/.git')).writeAsStringSync('gitdir: ../real/.git\n');
      final found = findGitRemoteExposure(mkdir('repo/vault'))!;
      expect(found.remotes.single.name, 'up');
      expect(found.remotes.single.host, 'gitlab.com');
    });
  });

  group('주소의 자격 증명을 가린다', () {
    test('https 사용자:토큰은 가리고 호스트는 남긴다', () {
      final masked = maskRemoteUrl('https://me:ghp_abcdefghijklmnopqrstuvwxyz0123@github.com/x/y.git');
      expect(masked, isNot(contains('ghp_')));
      expect(masked, isNot(contains('me:')));
      expect(masked, contains('github.com/x/y.git'));
    });

    test('토큰만 사용자 자리에 있어도 가린다', () {
      expect(maskRemoteUrl('https://abc123secret@github.com/x/y.git'), isNot(contains('abc123secret')));
    });

    test('ssh 형식은 그대로 둔다', () {
      expect(maskRemoteUrl('git@github.com:x/y.git'), 'git@github.com:x/y.git');
      // 비밀번호에 @가 있어도 호스트 앞까지 가린다 (11/13 검토)
      expect(maskRemoteUrl('https://u:p@ss@github.com/x/y.git'), isNot(contains('ss@')));
      expect(remoteHost('https://u:p@ss@github.com/x/y.git'), 'github.com');
      expect(remoteHost('git@github.com:x/y.git'), 'github.com');
      expect(remoteHost('ssh://git@github.com:22/x/y.git'), 'github.com');
      expect(remoteHost('/Volumes/백업/y.git'), '로컬 경로');
    });
  });

  group('실제 git으로 만든 폴더', () {
    final hasGit = _hasGit();

    String repo() {
      final root = mkdir('repo');
      _git(root, ['init', '-q']);
      return root;
    }

    test('(a) git 밖이면 조용하다', () {
      expect(findGitRemoteExposure(mkdir('vault')), isNull);
    }, skip: hasGit ? false : 'git이 없다');

    test('(b) git init만 하고 원격이 없으면 조용하다', () {
      final root = repo();
      expect(findGitRemoteExposure(root), isNull);
      expect(findGitRemoteExposure(mkdir('repo/vault')), isNull);
    }, skip: hasGit ? false : 'git이 없다');

    test('(c) 원격 origin을 붙이면 경고한다', () {
      final root = repo();
      _git(root, ['remote', 'add', 'origin', 'https://github.com/x/y.git']);
      final found = findGitRemoteExposure(root)!;
      expect(found.remotes.single.name, 'origin');
      expect(found.remotes.single.url, 'https://github.com/x/y.git');
      expect(found.warning, contains('github.com'));
    }, skip: hasGit ? false : 'git이 없다');

    test('(d) 그런 저장소의 하위 폴더도 경고한다', () {
      final root = repo();
      _git(root, ['remote', 'add', 'origin', 'https://github.com/x/y.git']);
      final found = findGitRemoteExposure(mkdir('repo/docs/SecondBrain'))!;
      expect(found.repoRoot, _real(root));
    }, skip: hasGit ? false : 'git이 없다');

    test('(e) 주소의 사용자:토큰은 경고에 나오지 않는다', () {
      final root = repo();
      _git(root, ['remote', 'add', 'origin', 'https://me:ghp_abcdefghijklmnopqrstuvwxyz0123@github.com/x/y.git']);
      final found = findGitRemoteExposure(root)!;
      expect(found.warning, isNot(contains('ghp_')));
      expect(found.remotes.single.url, isNot(contains('ghp_')));
      expect(found.warning, contains('github.com'));
    }, skip: hasGit ? false : 'git이 없다');

    test('(f) git worktree 안의 지식 폴더도 경고한다', () {
      final root = repo();
      _git(root, ['remote', 'add', 'origin', 'https://github.com/x/y.git']);
      _git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'x']);
      final wt = p.join(temp.path, 'wt');
      _git(root, ['worktree', 'add', '-q', wt]);
      final found = findGitRemoteExposure(mkdir('wt/vault'))!;
      expect(found.remotes.single.name, 'origin');
    }, skip: hasGit ? false : 'git이 없다');

    test('(g) .gitignore로 지식 폴더를 뺐으면 조용하다', () {
      final root = repo();
      _git(root, ['remote', 'add', 'origin', 'https://github.com/x/y.git']);
      File(p.join(root, '.gitignore')).writeAsStringSync('SecondBrain/\n');
      expect(findGitRemoteExposure(mkdir('repo/SecondBrain')), isNull);
      expect(findGitRemoteExposure(mkdir('repo/other')), isNotNull);
    }, skip: hasGit ? false : 'git이 없다');
  });
}

/// macOS 임시 폴더는 /var → /private/var 링크라 실제 경로로 비교한다.
String _real(String path) => Directory(path).resolveSymbolicLinksSync();

bool _hasGit() {
  try {
    return Process.runSync('git', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void _git(String dir, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: dir);
  if (result.exitCode != 0) throw StateError('git ${args.join(' ')}: ${result.stderr}');
}
