import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;

import '../brain_context.dart';
import 'hook_command.dart';

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
    argParser
      ..addOption(
        'queries',
        help: '질문 세트 (기본: 지식 폴더의 bench/questions.yaml)',
      )
      ..addOption(
        'lessons',
        help: '규칙 매칭 시험 (bench/lessons.yaml): 실수 노트 걸림·헛걸림, 미리 넣기(R2) 헛넣기도 함께 잰다',
      );
  }

  final BrainContext context;

  @override
  String get name => 'bench';

  @override
  String get description => '검색 품질과 속도를 잰다.';

  @override
  int run() {
    final lessonsPath = argResults!['lessons'] as String?;
    if (lessonsPath != null) return _lessons(lessonsPath);
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

  /// 규칙 매칭 시험 (기능검토 2절, 실수 노트 L-0008). 돈 안 드는 결정적 시험이다.
  /// ① 요청마다 붙는 실수 노트: 걸려야 할 요청 중 걸린 비율, 걸리면 안 될 요청 중 걸린 비율
  /// ② 미리 넣기(R2): 어느 노트와도 상관없는 요청(none)에 노트를 넣은 비율, 질문 세트에서 넣은 노트가 정답인 비율
  int _lessons(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('규칙 매칭 시험 파일이 없습니다: $path');
      return 1;
    }
    final cases = LessonCase.parseYaml(file.readAsStringSync());
    context.index.sync();
    final known = {for (final l in context.lessons.all()) l.id};
    final missing = [for (final c in cases) if (c.lesson != null && !known.contains(c.lesson)) c.lesson];
    if (missing.isNotEmpty) stdout.writeln('없는 실수 노트(건너뜀 아님, 모두 안 걸림으로 셈): ${missing.join(', ')}');
    final r = runLessonBench(context.lessons, cases);
    String pct(int a, int b) => '$a/$b (${b == 0 ? 0 : (a * 100 / b).round()}%)';
    stdout
      ..writeln('실수 노트 걸림 (걸려야 할 요청): ${pct(r.hitOk, r.hitTotal)}')
      ..writeln('헛걸림 (걸리면 안 될 요청에 그 규칙): ${pct(r.missWrong, r.missTotal)}')
      ..writeln('헛걸림 (다른 규칙이 걸림): ${r.otherWrong}번')
      ..writeln('관계없는 요청에 걸림: ${pct(r.noneWrong, r.noneTotal)}');
    for (final line in r.unmatched) {
      stdout.writeln('안 걸림: $line');
    }
    for (final line in r.wrong) {
      stdout.writeln('잘못 걸림: $line');
    }
    // R2 미리 넣기: 관계없는 요청에는 0개여야 하고, 질문 세트에서는 넣은 노트가 정답이어야 한다.
    final none = [for (final c in cases) if (c.lesson == null) ...c.miss];
    var noneInjected = 0;
    for (final text in none) {
      final docs = HookCommand.relatedNotes(context.index, text);
      if (docs.isNotEmpty) {
        noneInjected++;
        stdout.writeln('헛넣기: ${docs.map((d) => d.id).join(',')} ← $text');
      }
    }
    stdout.writeln('미리 넣기 — 관계없는 요청에 넣음: ${pct(noneInjected, none.length)}');
    final qPath = argResults!['queries'] as String? ?? p.join(p.dirname(path), 'questions.yaml');
    final qFile = File(qPath);
    if (qFile.existsSync()) {
      final questions = BenchQuestion.parseYaml(qFile.readAsStringSync());
      var injected = 0, correct = 0, wrongDocs = 0;
      for (final q in questions) {
        final docs = HookCommand.relatedNotes(context.index, q.question);
        if (docs.isEmpty) continue;
        injected++;
        if (docs.any((d) => q.expect.contains(d.id))) correct++;
        final bad = docs.where((d) => !q.expect.contains(d.id)).toList();
        wrongDocs += bad.length;
        if (bad.isNotEmpty) stdout.writeln('정답 밖 노트: ${bad.map((d) => d.id).join(',')} ← ${q.question}');
      }
      stdout
        ..writeln('미리 넣기 — 질문 ${questions.length}개 중 넣음 ${pct(injected, questions.length)}, 넣은 것 중 정답 포함 ${pct(correct, injected)}')
        ..writeln('미리 넣기 — 정답 밖 노트 $wrongDocs개');
    }
    return 0;
  }
}


/// `brain review [--days 7]`: 그 기간 변경 기록(`_log/`)으로 주간 회고 초안을 md로 낸다 (설계서 3.0 E7).
/// 파일로 저장하지 않는다 — 사용자가 고쳐서 주간 보고·노트에 쓴다.
class ReviewCommand extends Command<int> {
  ReviewCommand(this.context) {
    argParser.addOption('days', defaultsTo: '7', help: '며칠 치를 모을지');
  }

  final BrainContext context;

  @override
  String get name => 'review';

  @override
  String get description => '주간 회고 초안: 새 노트·고친 노트·실수 노트·할 일 (변경 기록에서).';

  @override
  int run() {
    final days = int.tryParse(argResults!['days'] as String) ?? 7;
    final since = DateTime.now().subtract(Duration(days: days));
    final events = readChangeHistory(context.vault).where((e) => e.at.isAfter(since)).toList();
    context.index.syncIfStale();
    String title(String id) => context.index.byId(id)?.title ?? '(지워졌거나 옮겨진 노트)';
    final added = <String>{}, changed = <String>{}, confirmed = <String>{}, lessons = <String>{}, todos = <String>[];
    for (final e in events) {
      final id = e.detail.split(' ').first;
      switch (e.action) {
        case 'add':
          added.add(id);
        case 'write' || 'update':
          changed.add(id);
        case 'status' when e.detail.contains(' active'):
          confirmed.add(id);
        case final a when a.startsWith('lesson-add') || a == 'lesson-edit':
          lessons.add(id);
        case 'todo-add' || 'todo-accept':
          todos.add(e.detail);
      }
    }
    changed.removeAll(added);
    String day(DateTime d) => '${d.month}/${d.day}';
    final out = StringBuffer()
      ..writeln('# 회고 초안 (${day(since)} ~ ${day(DateTime.now())}, 최근 $days일)')
      ..writeln()
      ..writeln('변경 기록 ${events.length}건에서 모았다. 고쳐서 쓰고, 맞지 않는 줄은 지운다.')
      ..writeln();
    void section(String head, Iterable<String> lines) {
      out.writeln('## $head (${lines.length})');
      if (lines.isEmpty) out.writeln('- 없음');
      for (final line in lines) {
        out.writeln('- $line');
      }
      out.writeln();
    }

    section('새 지식', [for (final id in added) if (id.startsWith('n_')) '$id ${title(id)}']);
    section('확인해 정리됨으로 보낸 노트', [for (final id in confirmed) if (id.startsWith('n_')) '$id ${title(id)}']);
    section('고친 노트', [for (final id in changed) if (id.startsWith('n_')) '$id ${title(id)}']);
    section('새로 배운 규칙 (실수 노트)', [
      for (final id in lessons)
        if (context.lessons.read(id) case final l?) '$id ${l.line}' else id,
    ]);
    section('할 일', todos);
    stdout.write(out.toString());
    return 0;
  }
}
