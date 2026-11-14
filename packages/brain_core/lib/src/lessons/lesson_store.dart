import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../log/change_log.dart';
import '../note/note.dart';
import '../note/note_store.dart';
import '../security/secret_mask.dart';
import '../text/nfc.dart';
import '../vault/vault.dart';
import 'lesson.dart';

/// 실수 노트·회귀 시험·검증 기준 읽기·쓰기 (설계서 5.4).
class LessonStore {
  LessonStore(this.vault, this.index, {this.syncOnRead = true});

  final Vault vault;
  final SearchIndex index;

  /// 읽기([all]) 전에 색인을 맞출지. CLI·훅은 켜고, 폴더 감시로 색인을 따로 맞추는 앱은 끈다
  /// (11/07 노트 1만 개 앱 시작: 여기서 전체 동기화가 화면 스레드에서 돌아 345ms).
  final bool syncOnRead;

  /// 질문당 넣는 규칙 최대 개수.
  static const maxPerPrompt = 3;

  /// 세션 시작 안내에 늘 넣는 적용 중 규칙 최대 개수 (설계서 5.4 안전장치). 넘으면 앱 [배운 것]이 합치기를 권한다
  /// (설계서_프롬프트이후 4.5).
  static const maxSessionLessons = 30;

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
    // 실수 노트는 세션 시작 안내에 늘 들어가 저장 금지 목록도 지킨다 (설계서_프롬프트이후 5.2, 11/13 검토).
    NoteStore(vault, index).checkForbidden(title: '', summary: '', body: '$trigger\n$action\n$reason');
    return withVaultLock(vault, () {
      vault.ensure();
      index.sync();
      final id = 'L-${(_nextNumber('L-')).toString().padLeft(4, '0')}';
      String? testId;
      // 회귀 시험이 상한(30개)이면 규칙만 저장하고 시험은 만들지 않는다. 예전에는 규칙까지 통째로 실패했고
      // 시험을 지울 명령도 없었다 (11/11 K-36). 부른 쪽은 testId가 null인 것으로 알고 `brain lesson tests --remove`를 안내한다.
      if ((question ?? '').trim().isNotEmpty &&
          (expect ?? '').trim().isNotEmpty &&
          index.docsOf('test').length < maxTests) {
        testId = 'T-${(_nextNumber('T-')).toString().padLeft(4, '0')}';
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
        created: DateTime.now(),
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
    });
  }

  /// 실수 노트·회귀 시험 id 모양. 경로가 되므로 이것만 받는다
  /// (11/11 K-18: `brain lesson set ../../outside`가 지식 폴더 밖 .md 맨 위에 frontmatter를 붙였다).
  static final idPattern = RegExp(r'^[LT]-\d{1,6}$');

  static void checkId(String id) {
    if (!idPattern.hasMatch(id)) {
      throw NoteStoreException('실수 노트 id 형식이 아닙니다: $id (예: L-0001)');
    }
  }

  int _nextNumber(String prefix) =>
      [
        index.maxNumber(prefix),
        maxLoggedNumber(vault, prefix),
      ].reduce((a, b) => a > b ? a : b) +
      1;

  Lesson? read(String id) {
    checkId(id);
    final file = File(p.join(vault.lessonsDir, '$id.md'));
    if (!file.existsSync()) return null;
    return Lesson.parse(file.readAsStringSync(), fallbackId: id);
  }

  List<Lesson> all({LessonStatus? status}) {
    // 훅이 요청마다 부르므로 빠른 동기화 (노트 1만 개에서 전체 동기화 140ms, 훅 목표 100ms)
    if (syncOnRead) index.syncIfStale();
    return [
      for (final doc in index.docsOf('lesson'))
        if (status == null || doc.statusText == status.value) ?read(doc.id),
    ];
  }

  /// 고치기는 지식 폴더 잠금 안에서 한다 (읽고 고쳐 쓰는 [setStatus]·[recordEvidence]도 읽기부터 잠금 안).
  /// 예전에는 훅·검증 에이전트가 동시에 근거 횟수를 올리면 덜 세졌다 (데이터 안전 감사 11/14: 90번 → 85).
  void save(Lesson lesson, {String action = 'lesson-update', String? batch}) => withVaultLock(vault, () {
    checkId(lesson.id);
    final path = p.join(vault.lessonsDir, '${lesson.id}.md');
    recordBeforeChange(vault, path, batch: batch);
    writeFileAtomic(path, lesson.toMarkdown());
    appendChangeLog(
      vault,
      action,
      '${lesson.id} ${lesson.status.value}',
      batch: batch,
    );
    index.sync();
  });

  void setStatus(String id, LessonStatus status, {String? batch}) => withVaultLock(vault, () {
    final lesson = read(id);
    if (lesson == null) throw NoteStoreException('$id 실수 노트가 없습니다.');
    save(
      lesson.copyWith(status: status),
      action: 'lesson-status',
      batch: batch,
    );
  });

  /// 규칙을 지켜 문제없었으면 kept, 다시 교정됐으면 recorrected를 하나 올린다.
  void recordEvidence(String id, {required bool kept, String? batch}) => withVaultLock(vault, () {
    final lesson = read(id);
    if (lesson == null) throw NoteStoreException('$id 실수 노트가 없습니다.');
    save(
      lesson.copyWith(
        kept: lesson.kept + (kept ? 1 : 0),
        recorrected: lesson.recorrected + (kept ? 0 : 1),
        lastSeen: DateTime.now(),
        // 다시 교정된 날은 세션 시작 목록에서 규칙을 앞으로 올린다 (설계서_프롬프트이후 4.5)
        recorrectedAt: kept ? null : DateTime.now(),
      ),
      action: 'lesson-evidence',
      batch: batch,
    );
  });

  /// 세션 시작 안내에 넣을 적용 중 규칙: 최근에 만들었거나 다시 교정된 것부터 [maxSessionLessons]개
  /// (설계서_프롬프트이후 4.5, K-41: 번호 순이면 규칙 40개에서 최근 10개가 0/10 전달).
  /// [legacy]면 이전 방식 그대로 번호 순 앞 30개 (7.3 "이전 방식" 스위치).
  /// 돌려주는 두 번째 값은 목록에서 빠진 적용 중 규칙 수.
  (List<Lesson>, int) sessionLessons({bool legacy = false}) {
    final active = all(status: LessonStatus.active);
    active.sort(legacy ? (a, b) => a.id.compareTo(b.id) : Lesson.recentFirst);
    final rest = active.length - maxSessionLessons;
    return (active.take(maxSessionLessons).toList(), rest > 0 ? rest : 0);
  }

  /// 비슷한 규칙 쌍 (설계서_프롬프트이후 4.5 "합치기 필요"). AI 없이 언제·무엇을의 단어 머리가 겹치는 비율로 본다:
  /// 겹친 머리 2개 이상이고, 짧은 쪽 머리의 절반 이상이 겹치면 후보. 많이 겹친 쌍부터 [limit]개.
  static List<(Lesson, Lesson, double)> similarPairs(List<Lesson> lessons, {int limit = 5}) {
    final heads = [for (final l in lessons) wordHeads('${l.trigger} ${l.action}').toSet()];
    final out = <(Lesson, Lesson, double)>[];
    for (var i = 0; i < lessons.length; i++) {
      for (var j = i + 1; j < lessons.length; j++) {
        final shared = heads[i].intersection(heads[j]).length;
        final smaller = heads[i].length < heads[j].length ? heads[i].length : heads[j].length;
        if (shared < 2 || smaller == 0) continue;
        final ratio = shared / smaller;
        if (ratio >= matchRatio) out.add((lessons[i], lessons[j], ratio));
      }
    }
    out.sort((a, b) => b.$3.compareTo(a.$3));
    return out.take(limit).toList();
  }

  /// 두 규칙을 한 문장으로 합친다 (설계서_프롬프트이후 4.5). [keepId]는 새 문장으로 고쳐 남기고 [dropId]는 보관한다.
  /// 지움이 아니라 보관이라 [배운 것]에서 복원할 수 있고, 같은 묶음이라 `brain undo`로 함께 되돌린다.
  void merge(
    String keepId,
    String dropId, {
    required String trigger,
    required String action,
    required String reason,
    String? batch,
  }) {
    if (keepId == dropId) throw const NoteStoreException('같은 규칙끼리는 합칠 수 없습니다.');
    for (final (name, value) in [('trigger', trigger), ('action', action), ('reason', reason)]) {
      if (value.trim().isEmpty) throw NoteStoreException('$name이 비었습니다 (언제 → 무엇을 → 왜).');
    }
    NoteStore(vault, index).checkForbidden(title: '', summary: '', body: '$trigger\n$action\n$reason');
    // 잠금 안에서 읽고 쓴다: 그사이 훅의 `lesson evidence`가 같은 규칙을 고치면 그 기록이 사라졌다 (11/13 검토).
    withVaultLock(vault, () => _merge(keepId, dropId, trigger: trigger, action: action, reason: reason, batch: batch));
  }

  void _merge(
    String keepId,
    String dropId, {
    required String trigger,
    required String action,
    required String reason,
    String? batch,
  }) {
    final keep = read(keepId), drop = read(dropId);
    if (keep == null) throw NoteStoreException('$keepId 실수 노트가 없습니다.');
    if (drop == null) throw NoteStoreException('$dropId 실수 노트가 없습니다.');
    // 이미 보관된 규칙을 다시 합치면 횟수가 두 번 더해지고, 남길 쪽이 보관돼 있으면 둘 다 목록에서 빠졌다.
    for (final l in [keep, drop]) {
      if (l.status != LessonStatus.active) throw NoteStoreException('${l.id}는 적용 중이 아니라 합칠 수 없습니다 (화면을 새로 보세요).');
    }
    final batchId = batch ?? newBatchId();
    final day = formatTime(DateTime.now()).substring(0, 10);
    String note(String body, String line) => [if (body.trim().isNotEmpty) body.trim(), line].join('\n');
    save(
      keep.copyWith(
        trigger: maskSecrets(trigger.trim()),
        action: maskSecrets(action.trim()),
        reason: maskSecrets(reason.trim()),
        // 지킴·다시 교정 횟수는 두 규칙 것을 더한다 (같은 규칙이었으므로)
        kept: keep.kept + drop.kept,
        recorrected: keep.recorrected + drop.recorrected,
        body: note(keep.body, '- $day ${drop.id}와 합침 (앞 문장: ${keep.line})'),
      ),
      action: 'lesson-merge',
      batch: batchId,
    );
    save(
      drop.copyWith(
        status: LessonStatus.archived,
        body: note(drop.body, '- $day ${keep.id}로 합쳐 보관'),
      ),
      action: 'lesson-merge',
      batch: batchId,
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
      for (final m in RegExp(
        r'[a-z0-9_]{2,}|[^\x00-\x7f\p{P}\p{S}]+',
        unicode: true,
      ).allMatches(word)) {
        final part = m.group(0)!;
        final runes = part.runes.toList();
        final head = part.codeUnitAt(0) < 0x80
            ? part
            : (runes.length >= 2 ? String.fromCharCodes(runes.take(2)) : '');
        if (head.isNotEmpty &&
            !_stopwords.contains(head) &&
            !heads.contains(head)) {
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

  /// 회귀 시험 하나를 지운다 (상한에서 자리를 만들 때). 그 시험을 가진 실수 노트의 목록에서도 뺀다.
  /// 지우기 전 사본을 남겨 `brain undo <묶음>`으로 되돌릴 수 있다.
  void removeTest(String testId, {String? batch}) => withVaultLock(vault, () {
    checkId(testId);
    if (!testId.startsWith('T-')) throw NoteStoreException('회귀 시험 id가 아닙니다: $testId (예: T-0001)');
    final batchId = batch ?? newBatchId();
    final path = p.join(vault.lessonsDir, 'tests', '$testId.md');
    final file = File(path);
    if (!file.existsSync()) throw NoteStoreException('$testId 회귀 시험이 없습니다.');
    final owner = LessonTest.parse(file.readAsStringSync(), fallbackId: testId).lesson;
    recordBeforeChange(vault, path, batch: batchId);
    file.deleteSync();
    final lesson = owner.isEmpty ? null : read(owner);
    if (lesson != null && lesson.tests.contains(testId)) {
      save(
        lesson.copyWith(tests: [for (final t in lesson.tests) if (t != testId) t]),
        action: 'lesson-update',
        batch: batchId,
      );
    }
    appendChangeLog(vault, 'lesson-test-remove', '$testId ${owner.isEmpty ? '' : owner}'.trim(), batch: batchId);
    index.sync();
  });

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

  void addCheckItem(String item, {String? batch}) => withVaultLock(vault, () {
    final items = checklist();
    if (items.length >= maxChecklist) {
      throw const NoteStoreException('검사 기준이 30항목입니다. 비슷한 항목을 합친 뒤 추가하세요.');
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
  });
}
