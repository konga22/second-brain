import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;

import '../brain_context.dart';

/// `brain project`: 프로젝트 문맥 페이지 `wiki/프로젝트/<이름>/_project.md` (설계서_프롬프트이후 5.4).
class ProjectCommand extends Command<int> {
  ProjectCommand(BrainContext context) {
    addSubcommand(_ProjectSetCommand(context));
    addSubcommand(_ProjectShowCommand(context));
  }

  @override
  String get name => 'project';

  @override
  String get description => '프로젝트 문맥(지금 상태·다음 할 일): set, show';
}

/// 이름을 주면 그 페이지, 아니면 [path](없으면 지금 폴더)가 속한 프로젝트 이름.
String? _resolveName(ProjectContext projects, String? name, String? path) {
  if (name != null) return name;
  return projects.find(path ?? Directory.current.path)?.name;
}

/// `brain project set`: 사람이 등록하고(경로·이름), 진행을 적는다. 다른 절·글은 그대로 둔다.
///
/// AI 대화 안(`CLAUDECODE`·`CLAUDE_CODE_SESSION_ID`)에서는 `--state`·`--next`로 두 절만 고칠 수 있다. 등록과 경로는
/// 사용자가 정한다 — AI가 경로를 바꾸면 다른 폴더 세션에 엉뚱한 프로젝트 문맥이 붙는다.
class _ProjectSetCommand extends Command<int> {
  _ProjectSetCommand(this.context) {
    argParser
      ..addOption('name', help: '프로젝트 이름 (wiki/프로젝트/<이름>). 없으면 --path나 지금 폴더로 찾는다')
      ..addOption('path', help: '프로젝트 폴더 (절대 경로). 처음 만들 때 필요하다. 사람만')
      ..addOption('state', help: '"지금 상태" 절 본문으로 바꾼다 (- 면 표준 입력)')
      ..addOption('next', help: '"다음 할 일" 절 본문으로 바꾼다 (- 면 표준 입력)');
  }

  final BrainContext context;

  @override
  String get name => 'set';

  @override
  String get description => '프로젝트 문맥 페이지를 만들거나 고친다. AI 대화에서는 --state·--next만.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final rawPath = args['path'] as String?;
    var state = args['state'] as String?;
    var next = args['next'] as String?;
    if (isAiSessionEnv(Platform.environment)) {
      if (rawPath != null) {
        stderr.writeln('프로젝트 등록·경로는 사용자가 터미널에서 정합니다: brain project set --path <폴더> --name <이름>. '
            'AI는 --state·--next로 "지금 상태"·"다음 할 일"만 고칩니다.');
        return 1;
      }
      if (state == null && next == null) {
        stderr.writeln('고칠 절이 없습니다: --state "<지금 상태>" 또는 --next "<다음 할 일>"');
        return 1;
      }
    }
    if (state == '-' && next == '-') {
      stderr.writeln('표준 입력(-)은 --state·--next 중 하나에만 씁니다.');
      return 64;
    }
    if (state == '-' || next == '-') {
      final input = await readStdin() ?? '';
      if (state == '-') state = input;
      if (next == '-') next = input;
    }
    final projects = ProjectContext(context.vault);
    final path = rawPath == null ? null : p.absolute(rawPath);
    final name = _resolveName(projects, args['name'] as String?, path);
    if (name == null) {
      stderr.writeln('어느 프로젝트인지 모릅니다: --name <이름>을 주거나 프로젝트 폴더 안에서 부릅니다.');
      return 1;
    }
    try {
      final file = projects.set(name: name, path: path, state: state, next: next);
      stdout.writeln('프로젝트 문맥 저장: ${p.relative(file, from: context.vault.root)}${path == null ? '' : ' (경로 $path)'}');
      return 0;
    } on ProjectContextException catch (e) {
      stderr.writeln(e.message);
      return 1;
    }
  }
}

/// `brain project show`: 지금 폴더(또는 --name)의 프로젝트 문맥 — 세션 시작에 붙는 글과 같다.
class _ProjectShowCommand extends Command<int> {
  _ProjectShowCommand(this.context) {
    argParser.addOption('name', help: '프로젝트 이름. 없으면 지금 폴더로 찾는다');
  }

  final BrainContext context;

  @override
  String get name => 'show';

  @override
  String get description => '지금 폴더(또는 --name) 프로젝트의 지금 상태·다음 할 일';

  @override
  int run() {
    final projects = ProjectContext(context.vault);
    final name = argResults!['name'] as String?;
    ProjectPage? page;
    if (name == null) {
      page = projects.find(Directory.current.path);
    } else {
      final file = File(projects.pagePath(toNfc(name.trim())));
      if (file.existsSync()) page = ProjectPage.parse(toNfc(name.trim()), file.readAsStringSync());
    }
    if (page == null) {
      stderr.writeln(name == null
          ? '이 폴더는 등록된 프로젝트가 아닙니다. 사용자가 brain project set --path <폴더> --name <이름>으로 등록합니다.'
          : '프로젝트 "$name" 페이지가 없습니다.');
      return 1;
    }
    final lines = page.sessionLines();
    stdout.writeln(lines == null ? '프로젝트 "${page.name}": 지금 상태·다음 할 일이 비어 있습니다.' : lines.join('\n'));
    return 0;
  }
}
