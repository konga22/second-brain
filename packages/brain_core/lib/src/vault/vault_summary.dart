import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../lessons/lesson.dart';
import '../lessons/lesson_store.dart';
import '../vault/vault.dart';

/// 자동 생성 목차와 온보딩 요약 (설계서 4.1·5.2).
///
/// - `index.md`: 주제 폴더 목록과 노트 수. AI가 한 단계씩 좁혀 읽는다.
/// - `wiki/<주제>/index.md`: 그 주제의 노트 제목과 요약.
/// - `_profile.md`: 주요 주제 5개와 자주 받은 교정 3개. SessionStart 훅이 넣는다 (150토큰 이하).
///
/// 내용이 같으면 파일을 다시 쓰지 않는다 (폴더 감시가 쓸데없이 깨지 않게).
class VaultSummary {
  VaultSummary(this.vault, this.index);

  final Vault vault;
  final SearchIndex index;

  /// 온보딩 요약 최대 글자 수. 한글 1글자 ≈ 1토큰으로 보고 150토큰 안에 둔다.
  static const profileMaxChars = 300;

  /// 부르는 쪽(노트 저장·`brain index`·실수 노트 승인)은 바로 앞에서 색인을 맞춘다. 여기서 다시 맞추면
  /// 방금 쓴 폴더의 시각 때문에 전체 동기화가 한 번 더 돌아 1만 개에서 저장 1회에 약 80ms가 더 들었다 (11/12 측정, O-5).
  void writeAll() {
    // 자주 받은 교정: 적용 중인 실수 노트를 근거(지킨 횟수 + 다시 교정된 횟수)가 많은 순으로.
    final lessons = LessonStore(vault, index, syncOnRead: false).all(status: LessonStatus.active)
      ..sort(
        (a, b) => (b.kept + b.recorrected).compareTo(a.kept + a.recorrected),
      );
    final lessonLines = [for (final l in lessons.take(3)) l.line];
    final notes = index.notes().where((d) => !d.isMerged).toList();
    final byTopic = <String, List<IndexedDoc>>{};
    for (final doc in notes) {
      byTopic.putIfAbsent(doc.topic, () => []).add(doc);
    }
    final topics = byTopic.keys.toList()
      ..sort((a, b) => byTopic[b]!.length.compareTo(byTopic[a]!.length));

    final root = StringBuffer()
      ..writeln('# 지식 폴더 목차 (자동 생성)')
      ..writeln()
      ..writeln('노트 ${notes.length}개. 주제를 고른 뒤 `wiki/<주제>/index.md`나 `brain find`로 좁힌다.')
      ..writeln();
    for (final topic in topics) {
      final docs = byTopic[topic]!;
      final drafts = docs.where((d) => d.isDraft).length;
      root.writeln(
        '- $topic — 노트 ${docs.length}개${drafts > 0 ? ' (정리 대기 $drafts)' : ''}',
      );
      final topicIndex = StringBuffer()
        ..writeln('# $topic (자동 생성)')
        ..writeln();
      for (final doc in docs..sort((a, b) => a.title.compareTo(b.title))) {
        final summary = doc.summary.isEmpty ? '' : ' — ${doc.summary}';
        topicIndex.writeln(
          '- ${doc.id} ${doc.title}$summary${doc.isDraft ? ' [초안]' : ''}',
        );
      }
      _writeIfChanged(
        p.join(vault.wikiDir, topic, 'index.md'),
        topicIndex.toString(),
      );
    }
    _writeIfChanged(p.join(vault.root, 'index.md'), root.toString());
    _writeIfChanged(vault.profilePath, profile(topics, byTopic, lessonLines));
  }

  String profile(
    List<String> topics,
    Map<String, List<IndexedDoc>> byTopic,
    List<String> lessonLines,
  ) {
    final top = topics
        .take(5)
        .map((t) => '$t(${byTopic[t]!.length})')
        .join(', ');
    final lines = [
      '# 사용자 지식 요약 (자동 생성)',
      if (top.isNotEmpty) '- 주요 주제: $top',
      if (lessonLines.isNotEmpty) '- 자주 받은 교정: ${lessonLines.take(3).join(' / ')}',
      '- 관련 질문이면 먼저 `brain find <검색어>`로 찾는다.',
    ];
    var text = '${lines.join('\n')}\n';
    if (text.runes.length > profileMaxChars) {
      text = '${String.fromCharCodes(text.runes.take(profileMaxChars - 1))}…\n';
    }
    return text;
  }

  void _writeIfChanged(String path, String content) {
    final file = File(path);
    if (file.existsSync()) {
      final old = file.readAsStringSync();
      if (old == content) return;
      // 우리가 만든 파일(첫 줄에 "(자동 생성)")만 다시 쓴다. 이미 있던 폴더(Obsidian 등)를 지식 폴더로 고르면
      // 사용자의 index.md·_profile.md를 사본 없이 덮어썼다 (11/11 K-33).
      final firstLine = old.split('\n').first;
      if (!firstLine.contains('(자동 생성)')) return;
    }
    writeFileAtomic(path, content);
  }
}
