import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../log/change_log.dart';
import '../note/note_store.dart';
import '../security/secret_mask.dart';
import '../text/nfc.dart';
import '../vault/vault.dart';
import 'lesson.dart';

/// 실수 노트·회귀 시험·검증 기준 읽기·쓰기 (설계서 5.4).
class LessonStore {
  LessonStore(this.vault, this.index);

  final Vault vault;
  final SearchIndex index;

  /// 질문당 넣는 규칙 최대 개수.
  static const maxPerPrompt = 3;

  /// 검증 기준·회귀 시험 최대 개수. 넘으면 검증 에이전트가 비슷한 것을 합친다.
  static const maxChecklist = 30;
  static const maxTests = 30;

  /// 상황과 trigger가 이만큼 겹쳐야 맞는 규칙으로 본다 (trigger 조각 중 비율).
  static const matchRatio = 0.5;

  String get verifierPath => p.join(vault.lessonsDir, '_verifier.md');

  /// 새 실수 노트. 회귀 시험 사례(question·bad·expect)를 주면 함께 만든다.
  (String, String?) add({
    required String trigger,
    required String action,
    required String reason,
    String diff = '',
    String source = 'explicit',
    LessonStatus status = LessonStatus.pending,
    String? question,
    String? bad,
    String? expect,
    String? batch,
  }) {
    for (final (name, value) in [
      ('trigger', trigger),
      ('action', action),
      ('reason', reason),
    ]) {
      if (value.trim().isEmpty) {
        throw NoteStoreException('$name이 비었습니다 (언제 → 무엇을 → 왜).');
      }
    }
    vault.ensure();
    index.sync();
    final id = 'L-${(index.maxNumber('L-') + 1).toString().padLeft(4, '0')}';
    String? testId;
    if ((question ?? '').trim().isNotEmpty && (expect ?? '').trim().isNotEmpty) {
      if (index.docsOf('test').length >= maxTests) {
        throw const NoteStoreException(
          '회귀 시험이 30개를 넘습니다. 비슷한 시험을 합친 뒤 추가하세요.',
        );
      }
      testId = 'T-${(index.maxNumber('T-') + 1).toString().padLeft(4, '0')}';
      final test = LessonTest(
        id: testId,
        lesson: id,
        question: maskSecrets(question!.trim()),
        bad: maskSecrets((bad ?? '').trim()),
        expect: maskSecrets(expect!.trim()),
      );
      final testPath = p.join(vault.lessonsDir, 'tests', '$testId.md');
      recordBeforeChange(vault, testPath, batch: batch);
      writeFileAtomic(testPath, test.toMarkdown());
    }
    final lesson = Lesson(
      id: id,
      trigger: maskSecrets(trigger.trim()),
      action: maskSecrets(action.trim()),
      reason: maskSecrets(reason.trim()),
      diff: maskSecrets(diff),
      source: source,
      status: status,
      tests: [?testId],
      body: '',
    );
    final path = p.join(vault.lessonsDir, '$id.md');
    recordBeforeChange(vault, path, batch: batch);
    writeFileAtomic(path, lesson.toMarkdown());
    appendChangeLog(
      vault,
      'lesson-add',
      '$id ${status.value}${testId == null ? '' : ' $testId'}',
      batch: batch,
    );
    index.sync();
    return (id, testId);
  }

  Lesson? read(String id) {
    final file = File(p.join(vault.lessonsDir, '$id.md'));
    if (!file.existsSync()) return null;
    return Lesson.parse(file.readAsStringSync(), fallbackId: id);
  }

  List<Lesson> all({LessonStatus? status}) {
    // 훅이 요청마다 부르므로 빠른 동기화 (노트 1만 개에서 전체 동기화 140ms, 훅 목표 100ms)
    index.syncIfStale();
    return [
      for (final doc in index.docsOf('lesson'))
        if (status == null || doc.statusText == status.value)
          ?read(doc.id),
    ];
  }

  void save(Lesson lesson, {String action = 'lesson-update', String? batch}) {
    final path = p.join(vault.lessonsDir, '${lesson.id}.md');
    recordBeforeChange(vault, path, batch: batch);
    writeFileAtomic(path, lesson.toMarkdown());
    appendChangeLog(vault, action, '${lesson.id} ${lesson.status.value}', batch: batch);
    index.sync();
  }

  void setStatus(String id, LessonStatus status, {String? batch}) {
    final lesson = read(id);
    if (lesson == null) throw NoteStoreException('$id 실수 노트가 없습니다.');
    save(lesson.copyWith(status: status), action: 'lesson-status', batch: batch);
  }

  /// 규칙을 지켜 문제없었으면 kept, 다시 교정됐으면 recorrected를 하나 올린다.
  void recordEvidence(String id, {required bool kept, String? batch}) {
    final lesson = read(id);
    if (lesson == null) throw NoteStoreException('$id 실수 노트가 없습니다.');
    save(
      lesson.copyWith(
        kept: lesson.kept + (kept ? 1 : 0),
        recorrected: lesson.recorrected + (kept ? 0 : 1),
        lastSeen: DateTime.now(),
      ),
      action: 'lesson-evidence',
      batch: batch,
    );
  }

  /// 상황(질문·작업 설명)에 맞는 적용 중 규칙 최대 3개.
  ///
  /// trigger의 단어 머리(한글은 앞 2글자 — 조사·어미가 붙어도 같다, 영어는 단어)가
  /// 상황에 절반 이상 들어 있으면 맞는 규칙으로 본다. 규칙 수가 적어(수십 개) 색인 대신 직접 센다.
  /// 맞는 규칙이 없으면 빈 목록 → 훅은 0토큰.
  List<Lesson> match(String situation, {int limit = maxPerPrompt}) {
    final text = toNfc(situation).toLowerCase();
    if (text.trim().isEmpty) return const [];
    final scored = <(Lesson, double)>[];
    for (final lesson in all(status: LessonStatus.active)) {
      final heads = wordHeads(lesson.trigger);
      if (heads.isEmpty) continue;
      final matched = heads.where(text.contains).length;
      final ratio = matched / heads.length;
      if (matched >= 1 && ratio >= matchRatio) scored.add((lesson, ratio));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (lesson, _) in scored.take(limit)) lesson];
  }

  static const _stopwords = {'때', '경우', '할', '시', '중', '것', '수', '때는', '때에'};

  /// "결제 코드를 수정할 때" → [결제, 코드, 수정]. "push할" → [push].
  static List<String> wordHeads(String trigger) {
    final heads = <String>[];
    for (final word in toNfc(trigger).toLowerCase().split(RegExp(r'\s+'))) {
      if (word.isEmpty || _stopwords.contains(word)) continue;
      for (final m in RegExp(r'[a-z0-9_]{2,}|[^\x00-\x7f\p{P}\p{S}]+', unicode: true)
          .allMatches(word)) {
        final part = m.group(0)!;
        final runes = part.runes.toList();
        final head = part.codeUnitAt(0) < 0x80
            ? part
            : (runes.length >= 2 ? String.fromCharCodes(runes.take(2)) : '');
        if (head.isNotEmpty && !_stopwords.contains(head) && !heads.contains(head)) {
          heads.add(head);
        }
      }
    }
    return heads;
  }

  /// 규칙 후보와 관련된 회귀 시험 최대 5개 (BM25).
  List<LessonTest> testsFor(String text, {int limit = 5}) => [
    for (final doc in index.search(text, limit: limit, kinds: {'test'}))
      ?_readTest(doc.path),
  ];

  List<LessonTest> allTests() => [
    for (final doc in index.docsOf('test')) ?_readTest(doc.path),
  ];

  LessonTest? _readTest(String rel) {
    final file = File(p.join(vault.root, rel));
    if (!file.existsSync()) return null;
    return LessonTest.parse(
      file.readAsStringSync(),
      fallbackId: p.basenameWithoutExtension(rel),
    );
  }

  /// 검증 에이전트 검사 기준 (`lessons/_verifier.md`, 최대 30항목).
  List<String> checklist() {
    final file = File(verifierPath);
    if (!file.existsSync()) return const [];
    return [
      for (final line in file.readAsLinesSync())
        if (line.startsWith('- ')) line.substring(2).trim(),
    ];
  }

  void addCheckItem(String item, {String? batch}) {
    final items = checklist();
    if (items.length >= maxChecklist) {
      throw const NoteStoreException(
        '검사 기준이 30항목입니다. 비슷한 항목을 합친 뒤 추가하세요.',
      );
    }
    recordBeforeChange(vault, verifierPath, batch: batch);
    writeFileAtomic(
      verifierPath,
      [
        '# 검증 에이전트 검사 기준 (최대 30항목, 회귀 시험을 통과할 때만 바뀐다)',
        '',
        for (final i in [...items, maskSecrets(item.trim())]) '- $i',
        '',
      ].join('\n'),
    );
    appendChangeLog(vault, 'verifier-add', item.trim(), batch: batch);
  }

}
