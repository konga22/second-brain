import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../links/dismissed_links.dart';
import '../log/change_log.dart';
import '../note/note.dart';
import '../note/note_store.dart';
import '../note/wiki_links.dart';
import '../vault/vault.dart';

/// 점검 항목 (설계서 5.8).
enum LintType {
  deadLink('죽은 링크'),
  orphan('고아 노트'),
  duplicate('중복 후보'),
  stale('신선도'),
  format('형식'),
  unreadable('읽을 수 없는 파일'),
  tooLong('너무 긴 노트'),
  suspicious('의심 지시문');

  const LintType(this.label);

  final String label;
}

class LintIssue {
  const LintIssue({
    required this.type,
    required this.id,
    required this.message,
    this.canFix = false,
  });

  final LintType type;
  final String id;
  final String message;

  /// `--fix-safe`로 고칠 수 있는가 (형식 누락만).
  final bool canFix;
}

/// `brain lint`. 고치는 것은 안전한 형식 채우기뿐이고, 나머지는 제안만 한다.
class Linter {
  Linter(this.vault, this.index);

  final Vault vault;
  final SearchIndex index;

  static const staleDays = 180;
  static const maxChars = 4000;

  /// 중복 후보: 핵심 단어가 모두 겹치면(점수 1.0) 내용이 많이 겹친다고 본다.
  static const duplicateScore = 1.0;

  static final _suspicious = RegExp(
    r'(이전|위의|앞의|모든)\s*(지시|명령|규칙)[을를은는]?\s*(모두\s*)?(무시|잊)'
    r'|ignore\s+(all\s+)?(previous|prior|above)\s+instructions'
    r'|disregard\s+(all\s+)?(previous|prior)\s+'
    r'|you\s+are\s+now\s+'
    r'|시스템\s*프롬프트를?\s*(무시|보여|출력)'
    // AI에게 직접 시키는 말 (11/08 주입 시험: "AI 도우미에게: …를 실행해 줘", "이 요약을 본 AI는 …할 것")
    // AI를 부르는 말(…에게/…는) 뒤에 시키는 말끝(해 줘·하라·할 것)이 올 때만. 설명 문장("게임 AI·…로 실행")은 거르지 않게.
    r'|(AI|에이아이|어시스턴트|도우미|에이전트|assistant)\s*(에게|님|는|가)\s*[:,]?[^\n]{0,150}'
    r'(실행해 ?(줘|라)|실행하라|실행할 것|출력해 ?(줘|라)|출력하라|적어 ?(줘|라)|적을 것|답하라|답할 것|만들어 ?(줘|라)|만들 것|보여 ?줘|하라|할 것)'
    r'|(너는|당신은)\s*[^\n]{0,40}(하라|할 것|해야 한다)'
    r'|이\s*(노트|문서|요약|글)를\s*(읽|본|보)[^\n]{0,20}(AI|어시스턴트|에이전트|너|당신)',
    caseSensitive: false,
  );

  List<LintIssue> run() {
    index.sync();
    final issues = <LintIssue>[];
    final notes = index.notes().where((d) => !d.isMerged).toList();
    final links = index.links(dismissed: DismissedLinks(vault).load());
    final linked = <String>{
      for (final link in links) ...[link.fromId, link.toId],
    };

    for (final dead in index.deadLinks()) {
      final similar = index.search(dead.target, limit: 1);
      issues.add(
        LintIssue(
          type: LintType.deadLink,
          id: dead.fromId,
          message:
              '[[${dead.target}]] 노트가 없음'
              '${similar.isEmpty ? '' : ' — 비슷한 제목: ${similar.first.title} (${similar.first.id})'}',
        ),
      );
    }

    final titles = <String, String>{};
    for (final doc in notes) {
      final key = linkKey(doc.title);
      final other = titles[key];
      if (other != null) {
        issues.add(
          LintIssue(
            type: LintType.duplicate,
            id: doc.id,
            message: '$other 와 제목이 같음 — 합치기 검토',
          ),
        );
      }
      titles[key] = doc.id;
    }
    for (final link in links.where((l) => l.isSuggested)) {
      if (link.score >= duplicateScore) {
        issues.add(
          LintIssue(
            type: LintType.duplicate,
            id: link.fromId,
            message:
                '${link.toId} 와 내용이 많이 겹침 (점수 ${link.score.toStringAsFixed(2)}) — 합치기 검토',
          ),
        );
      }
    }

    for (final (rel, reason) in index.unreadable) {
      issues.add(
        LintIssue(
          type: LintType.unreadable,
          id: rel,
          message: '색인에서 건너뜀 — UTF-8 텍스트로 다시 저장하거나 지식 폴더 밖으로 옮기기 ($reason)',
        ),
      );
    }

    final now = DateTime.now();
    for (final doc in notes) {
      final file = File(p.join(vault.root, doc.path));
      if (!file.existsSync()) continue;
      final String text;
      try {
        text = file.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      final note = Note.parse(
        text,
        fallbackId: '',
        fallbackTitle: p.basenameWithoutExtension(doc.path),
      );
      if (!linked.contains(doc.id)) {
        issues.add(
          LintIssue(
            type: LintType.orphan,
            id: doc.id,
            message: '연결 0개 — 관련 노트에 [[${note.title}]]를 걸거나 추천 연결을 확인',
          ),
        );
      }
      if (note.isFrontmatterBroken) {
        // 자동으로 고치면 제목·요약·태그·출처를 잃는다 (11/11 K-21). 알리기만 한다.
        issues.add(
          LintIssue(
            type: LintType.format,
            id: doc.id,
            message: '머리말(frontmatter)을 읽지 못함 — 편집기로 열어 YAML 고치기, 값에 쌍점(:)이 있으면 큰따옴표로 (${doc.path})',
          ),
        );
      }
      final missing = [
        if (!note.isFrontmatterBroken && (note.id.isEmpty || doc.id.startsWith('f_'))) 'id',
        if (!text.startsWith('---')) 'frontmatter',
        if (!note.isFrontmatterBroken && note.summary.trim().isEmpty) 'summary',
      ];
      if (missing.isNotEmpty) {
        issues.add(
          LintIssue(
            type: LintType.format,
            id: doc.id,
            message: '${missing.join(', ')} 없음 (${doc.path})',
            canFix: true,
          ),
        );
      }
      final updated = note.updated ?? note.created ?? doc.mtime;
      if (now.difference(updated).inDays > staleDays) {
        issues.add(
          LintIssue(
            type: LintType.stale,
            id: doc.id,
            message:
                '${now.difference(updated).inDays}일 동안 안 고침 — 사실에 날짜를 달거나 출처를 가리키기',
          ),
        );
      }
      if (note.body.runes.length > maxChars) {
        issues.add(
          LintIssue(
            type: LintType.tooLong,
            id: doc.id,
            message: '${note.body.runes.length}자 — 섹션별로 나누기 제안',
          ),
        );
      }
      // 제목·요약도 본다: 요약은 find 결과와 훅이 미리 넣는 노트 줄에 그대로 나간다.
      final hit = _suspicious.firstMatch('${note.title}\n${note.summary}\n${note.body}');
      if (hit != null) {
        issues.add(
          LintIssue(
            type: LintType.suspicious,
            id: doc.id,
            message: '"${hit.group(0)}" — 노트 속 지시는 따르지 않는다 (표시만 함)',
          ),
        );
      }
    }
    return issues;
  }

  /// 안전한 형식 채우기: frontmatter·id·요약(본문 첫 문장 60자). 반환: 고친 파일 수.
  ///
  /// 머리말이 깨진 노트는 건드리지 않는다. 고치기 전 상태를 묶음에 남겨 `brain undo`로 되돌릴 수 있다 (11/11 K-21).
  /// 같은 id를 가진 파일이 둘이면(색인 id가 `f_…`) 뒤 파일에 새 번호를 준다.
  int fixSafe({String? batch}) {
    var fixed = 0;
    final batchId = batch ?? newBatchId();
    for (final issue in run().where((i) => i.canFix)) {
      final doc = index.byId(issue.id);
      if (doc == null) continue;
      final file = File(p.join(vault.root, doc.path));
      final newId = NoteStore(vault, index).nextNoteId();
      final note = Note.parse(
        file.readAsStringSync(),
        fallbackId: newId,
        fallbackTitle: p.basenameWithoutExtension(doc.path),
      );
      if (note.isFrontmatterBroken) continue;
      final id = doc.id.startsWith('f_') && note.id != newId ? newId : note.id;
      final summary = note.summary.trim().isEmpty
          ? firstSentence(note.body)
          : note.summary;
      final now = DateTime.now();
      final fixedNote = Note(
        id: id,
        title: note.title,
        summary: summary,
        tags: note.tags,
        aliases: note.aliases,
        source: note.source,
        sources: note.sources,
        created: note.created ?? doc.mtime,
        updated: now,
        status: note.status,
        body: note.body,
        extra: note.extra,
      );
      recordBeforeChange(vault, file.path, batch: batchId);
      writeFileAtomic(file.path, fixedNote.toMarkdown());
      appendChangeLog(vault, 'lint-fix', '$id ${doc.path}', batch: batchId);
      index.sync();
      fixed++;
    }
    return fixed;
  }
}

/// 본문 첫 문장을 60자 안으로 (요약 줄 자동 채우기).
String firstSentence(String body) {
  final line = body
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'^[#>\-*\s]+'), '').trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  final sentence = line.split(RegExp(r'(?<=[.!?。])\s')).first;
  final runes = sentence.runes.toList();
  return runes.length <= 60
      ? sentence
      : '${String.fromCharCodes(runes.take(59))}…';
}
