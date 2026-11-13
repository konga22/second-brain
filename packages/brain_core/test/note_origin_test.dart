import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Vault vault;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('origin_');
    vault = Vault(p.join(temp.path, 'SecondBrain'));
    Directory(vault.rawSessionsDir).createSync(recursive: true);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Note noteWith(List<String> sources, {String summary = '요약'}) =>
      Note(id: 'n_0001', title: '제목', summary: summary, source: 'session', sources: sources, body: '본문');

  /// `archiveSession`이 만드는 것과 같은 모양의 축약본. 본문을 길게 해 머리말만 읽는지 본다.
  void writeRaw(String name, {required String logPath}) {
    final raw = Note(
      id: 'r_e080b491',
      title: '세션 e080b491 주간 보고 양식 정하기',
      summary: 'second-brain 대화 241개',
      source: 'session',
      sources: [logPath],
      created: DateTime(2026, 11, 9),
      body: '사용자: 안녕\n' * 20000,
    );
    File(p.join(vault.rawSessionsDir, name)).writeAsStringSync(raw.toMarkdown());
  }

  test('세션 축약본이 있으면 도구·프로젝트·세션 제목·대화 수를 푼다', () {
    writeRaw(
      '2026-10-29-e080b491.md',
      logPath: '/Users/me/.claude/projects/-Volumes-SecondBrain-second-brain/e080b491-0e9e.jsonl',
    );

    final origin = resolveOrigins(vault, noteWith(['raw/sessions/2026-10-29-e080b491.md'])).single;

    expect(origin.kind, NoteOriginKind.session);
    expect(origin.tool, 'Claude Code');
    expect(origin.project, 'second-brain');
    expect(origin.sessionId, 'e080b491');
    expect(origin.title, '주간 보고 양식 정하기');
    expect(origin.date, '2026-10-29');
    expect(origin.dialogueCount, 241);
    expect(origin.rawId, 'r_e080b491');
    expect(origin.shortLabel, 'Claude Code · second-brain 세션');
    expect(origin.detail, '2026-10-29 시작 · 세션 e080b491 · 대화 241개');
  });

  test('Codex 기록에서 온 세션은 Codex로 보인다', () {
    writeRaw('2026-11-01-e080b491.md', logPath: '/Users/me/.codex/sessions/2026/11/01/rollout.jsonl');

    final origin = resolveOrigins(vault, noteWith(['raw/sessions/2026-11-01-e080b491.md'])).single;

    expect(origin.tool, 'Codex');
    expect(origin.shortLabel, 'Codex · second-brain 세션');
  });

  test('축약본 파일이 없어도 경로의 날짜와 세션 id는 보인다', () {
    final origin = resolveOrigins(vault, noteWith(['raw/sessions/2026-10-02-4f2dd470.md'])).single;

    expect(origin.kind, NoteOriginKind.session);
    expect(origin.project, isNull);
    expect(origin.rawId, isNull);
    expect(origin.shortLabel, 'AI 대화 세션 4f2dd470');
    expect(origin.detail, '2026-10-02 시작 · 세션 4f2dd470');
  });

  test('가져온 파일은 파일 이름과 가져온 날로 보인다', () {
    final origin = resolveOrigins(vault, noteWith(['raw/imports/2026-11-07-참고레포_조사.md'])).single;

    expect(origin.kind, NoteOriginKind.importFile);
    expect(origin.shortLabel, '가져온 파일 · 참고레포_조사.md');
    expect(origin.detail, '2026-11-07 가져옴');
  });

  test('원본 노트의 대화 기록 경로는 요약에서 프로젝트를 읽는다', () {
    final raw = noteWith(
      ['/Users/me/.claude/projects/-Users-me-Desktop-AI-TOP-100/4f2dd470.jsonl'],
      summary: 'AI_TOP_100 대화 331개',
    );

    final origin = resolveOrigins(vault, raw).single;

    expect(origin.kind, NoteOriginKind.sessionLog);
    expect(origin.shortLabel, 'Claude Code · AI_TOP_100 대화 기록');
    expect(origin.dialogueCount, 331);
  });

  test('출처가 없는 노트와 모르는 경로', () {
    expect(resolveOrigins(vault, noteWith([])), isEmpty);
    final origin = resolveOrigins(vault, noteWith(['docs/메모.txt'])).single;
    expect(origin.kind, NoteOriginKind.other);
    expect(origin.shortLabel, '메모.txt');
    expect(origin.detail, isEmpty);
  });
}
