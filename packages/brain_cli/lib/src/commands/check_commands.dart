import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;

import '../brain_context.dart';

/// `brain lint [--fix-safe]`: 유형별 개수 + 상위 5개 (설계서 5.8).
class LintCommand extends Command<int> {
  LintCommand(this.context) {
    argParser
      ..addFlag('fix-safe', help: '형식 누락(id·요약)만 자동으로 채운다.', negatable: false)
      ..addOption('type', help: '이 유형만 모두 보기 (dead, orphan, duplicate, stale, format, long, suspicious)');
  }

  final BrainContext context;

  @override
  String get name => 'lint';

  @override
  String get description => '지식 폴더를 점검한다 (죽은 링크·고아·중복·신선도·형식·길이·의심 지시문).';

  static const _typeNames = {
    'dead': LintType.deadLink,
    'orphan': LintType.orphan,
    'duplicate': LintType.duplicate,
    'stale': LintType.stale,
    'format': LintType.format,
    'long': LintType.tooLong,
    'suspicious': LintType.suspicious,
  };

  @override
  int run() {
    final linter = Linter(context.vault, context.index);
    if (argResults!['fix-safe'] as bool) {
      stdout.writeln('형식 자동 채움: ${linter.fixSafe()}개');
    }
    final only = _typeNames[argResults!['type']];
    final issues = linter.run();
    if (issues.isEmpty) {
      stdout.writeln('문제 없음');
      return 0;
    }
    for (final type in LintType.values) {
      if (only != null && type != only) continue;
      final ofType = issues.where((i) => i.type == type).toList();
      if (ofType.isEmpty) continue;
      stdout.writeln('${type.label} ${ofType.length}개');
      for (final issue in only == null ? ofType.take(5) : ofType) {
        stdout.writeln('  ${issue.id}  ${issue.message}');
      }
      if (only == null && ofType.length > 5) {
        stdout.writeln('  … 외 ${ofType.length - 5}개 (--type으로 모두 보기)');
      }
    }
    return 0;
  }
}

/// `brain bench [--queries 파일]`: recall@5·MRR·평균 ms (설계서 5.8).
class BenchCommand extends Command<int> {
  BenchCommand(this.context) {
    argParser.addOption(
      'queries',
      help: '질문 세트 (기본: 지식 폴더의 bench/questions.yaml)',
    );
  }

  final BrainContext context;

  @override
  String get name => 'bench';

  @override
  String get description => '검색 품질과 속도를 잰다.';

  @override
  int run() {
    final path =
        argResults!['queries'] as String? ??
        p.join(context.vault.root, 'bench', 'questions.yaml');
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('질문 세트가 없습니다: $path\n형식: - q: 질문\\n  expect: [n_0001]');
      return 1;
    }
    final questions = BenchQuestion.parseYaml(file.readAsStringSync());
    context.index.sync();
    final result = runBench(context.index, questions);
    stdout
      ..writeln('질문 ${result.count}개')
      ..writeln('recall@5 ${(result.recallAt5 * 100).toStringAsFixed(1)}%')
      ..writeln('MRR ${result.mrr.toStringAsFixed(3)}')
      ..writeln('평균 검색 ${result.averageMs.toStringAsFixed(2)}ms')
      ..writeln('find 출력 평균 ${result.averageChars.round()}자');
    for (final miss in result.misses.take(10)) {
      stdout.writeln('놓침: $miss');
    }
    return 0;
  }
}
