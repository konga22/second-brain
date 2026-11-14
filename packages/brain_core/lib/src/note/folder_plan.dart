import '../index/search_index.dart';
import '../text/nfc.dart';
import 'note_store.dart';
import 'zones.dart';

/// [폴더 정리] 첫 제안 한 줄 (설계서_프롬프트이후 5.1): 노트 / 지금 자리 / 제안 자리 / 제안 이름 + 까닭.
/// 추정이다. 확정은 사용자가 화면에서 한다.
class FolderProposal {
  const FolderProposal({
    required this.id,
    required this.title,
    required this.from,
    required this.topic,
    required this.name,
    required this.reason,
  });

  final String id;
  final String title;

  /// 지금 파일 경로 (지식 폴더 기준).
  final String from;

  /// 제안 자리 `구역/주제`.
  final String topic;

  /// 제안 파일 이름 (확장자 없이).
  final String name;

  /// 사용자에게 보이는 까닭 한 줄.
  final String reason;

  FolderMove toMove({String? topic, String? name}) => FolderMove(id: id, topic: topic ?? this.topic, name: name ?? this.name);
}

/// 주제 이름에 들어 있으면 그 구역으로 보는 말. 두 글자 이상은 포함, 한 글자(맥)는 낱말이 같을 때만.
const _zoneWords = {
  '생활·기기': ['맥', '아이폰', 'iphone', '아이패드', 'ipad', '갤럭시', '기기', '생활', '건강', '여행', '자동차', '살림', '가계부'],
  '조사·참고': ['레포', '참고', '조사', '자료', '도구', '링크', '논문', '북마크'],
  '공부': ['공부', '수업', '강의', '과제', '학교', '대학', '자격증', '어학', '교재'],
};

/// 기술 이름 (태그 → 개발 지식 주제 이름). 소문자·띄어쓰기·`-_.` 없이 맞춘다.
const _techNames = {
  'flutter': 'Flutter',
  'dart': 'Dart',
  'sqlite': 'SQLite',
  'claudecode': 'Claude Code',
  'supabase': 'Supabase',
  'swift': 'Swift',
  'swiftui': 'SwiftUI',
  'xcode': 'Xcode',
  'git': 'Git',
  'github': 'GitHub',
  'docker': 'Docker',
  'react': 'React',
  'reactnative': 'React Native',
  'node': 'Node.js',
  'nodejs': 'Node.js',
  'typescript': 'TypeScript',
  'javascript': 'JavaScript',
  'python': 'Python',
  'kotlin': 'Kotlin',
  'android': 'Android',
  'ios': 'iOS',
  'vercel': 'Vercel',
  'cloudflare': 'Cloudflare',
  'aws': 'AWS',
  'firebase': 'Firebase',
  'postgresql': 'PostgreSQL',
  'postgres': 'PostgreSQL',
  'astro': 'Astro',
  'mcp': 'MCP',
};

String _key(String text) => toNfc(text).toLowerCase().replaceAll(RegExp(r'[\s\-_.]'), '');

/// 같은 기술 태그 노트가 이만큼 있어야 프로젝트에서 개발 지식으로 뺀다 (하나짜리 주제를 늘리지 않게).
const _minTechNotes = 2;

/// 구역 밖(예전 방식) 노트마다 옮길 자리를 제안한다 (설계서_프롬프트이후 5.1). 파일을 바꾸지 않는다.
///
/// 1. 주제마다 구역 추정: 주제 이름의 말(맥·아이폰 → 생활·기기, 레포·참고·도구 → 조사·참고, 수업·강의 → 공부),
///    "○○ 개발"이거나 노트 3개 이상 중 80% 이상의 제목에 주제 이름이 있으면 프로젝트(`프로젝트/○○`), 그 밖은 개발 지식
/// 2. 프로젝트 주제의 노트 중 제목·요약·태그에 프로젝트 이름이 없고 태그가 기술 이름(Flutter·SQLite…)이거나
///    개발 지식으로 갈 다른 주제 이름이면 `개발 지식/<그 이름>` — 같은 이름으로 갈 노트가 2개 이상일 때만
/// 3. 파일 이름은 [shortNoteName]
List<FolderProposal> proposeFolderMoves(SearchIndex index) {
  final legacy = [for (final d in index.notes()) if (d.zone == null) d];
  final byTopic = <String, List<IndexedDoc>>{};
  for (final d in legacy) {
    byTopic.putIfAbsent(d.topicPath, () => []).add(d);
  }
  final guesses = {for (final e in byTopic.entries) e.key: _guessZone(e.key, e.value)};
  // 개발 지식으로 갈 주제 이름 (태그가 이 이름이면 그리로 모은다): 예전 주제 + 이미 구역 안에 있는 개발 지식 주제
  final devTopics = <String, String>{
    for (final t in index.zoneTopics('개발 지식')) _key(t): t,
    for (final g in guesses.values)
      if (g.$1 == '개발 지식') _key(g.$2): g.$2,
  };
  // 1차: 프로젝트 노트의 기술 후보
  final techOf = <String, String>{};
  for (final MapEntry(key: topic, value: docs) in byTopic.entries) {
    final (zone, name, _) = guesses[topic]!;
    if (zone != '프로젝트') continue;
    final project = _key(name);
    for (final doc in docs) {
      final tags = [for (final t in doc.tags.split(',')) if (t.trim().isNotEmpty) t.trim()];
      final text = _key('${doc.title} ${doc.summary} ${tags.join(' ')}');
      if (project.length >= 2 && text.contains(project)) continue;
      for (final tag in tags) {
        final tech = _techNames[_key(tag)] ?? devTopics[_key(tag)];
        if (tech != null) {
          techOf[doc.id] = tech;
          break;
        }
      }
    }
  }
  final techCount = <String, int>{};
  for (final tech in techOf.values) {
    techCount.update(tech, (n) => n + 1, ifAbsent: () => 1);
  }
  final out = <FolderProposal>[];
  // 같은 자리에 같은 짧은 이름이 둘이면 옮길 때 ` (2)`가 붙는다 — 화면에서 미리 보이게 이름에 붙여 둔다
  final taken = <String>{};
  String uniqueName(String topic, String name) {
    var candidate = name;
    for (var n = 2; !taken.add('$topic/${candidate.toLowerCase()}'); n++) {
      candidate = '$name ($n)';
    }
    return candidate;
  }

  for (final MapEntry(key: topic, value: docs) in byTopic.entries) {
    final (zone, name, reason) = guesses[topic]!;
    for (final doc in docs) {
      final tech = techOf[doc.id];
      final hasExisting = tech != null && devTopics.containsKey(_key(tech));
      final isTech = tech != null && (techCount[tech]! >= _minTechNotes || hasExisting);
      final target = isTech ? '개발 지식/$tech' : '$zone/$name';
      out.add(
        FolderProposal(
          id: doc.id,
          title: doc.title,
          from: doc.path,
          topic: target,
          name: uniqueName(target, shortNoteName(doc.title)),
          reason: isTech
              ? '태그 "$tech"(${_techNames.containsValue(tech) ? '기술' : '개발 지식 주제'})이고 제목·요약·태그에 "$name"이 없어 '
                    '다른 프로젝트에서도 쓸 지식으로 봄'
              : reason,
        ),
      );
    }
  }
  out.sort((a, b) => a.from.compareTo(b.from));
  return out;
}

/// 예전 주제 하나의 (구역, 주제 이름, 까닭).
(String, String, String) _guessZone(String topic, List<IndexedDoc> docs) {
  if (topic == '미분류') return ('개발 지식', '미분류', '주제가 없던 노트 — 화면에서 자리를 골라 주세요');
  // 구역 폴더 바로 아래에 있던 노트(`wiki/공부/a.md`)는 그 구역의 미분류로
  if (isZone(topic)) return (topic, '미분류', '구역 폴더 바로 아래에 있던 노트');
  final words = topic.toLowerCase().split(RegExp(r'\s+'));
  for (final MapEntry(key: zone, value: keys) in _zoneWords.entries) {
    for (final word in keys) {
      final hit = word.runes.length >= 2 ? topic.toLowerCase().contains(word) : words.contains(word);
      if (hit) return (zone, topic, '주제 이름의 "$word"');
    }
  }
  final project = topic.replaceFirst(RegExp(r'\s*개발$'), '').trim();
  if (project != topic && project.isNotEmpty) return ('프로젝트', project, '"○○ 개발" 주제');
  // 프로젝트 이름은 제목에 거의 늘 들어간다 (한반도감 13개 중 13개). 태그는 보지 않는다: 주제 이름을 태그로도 다는 일이 많아
  // "배포"·"챗봇" 같은 일반 주제까지 프로젝트로 보였다 (11/13 사본 측정). 노트가 적으면 우연이라 3개 이상만.
  final key = _key(topic);
  final mentions = docs.where((d) => _key(d.title).contains(key)).length;
  if (key.length >= 2 && docs.length >= 3 && mentions * 5 >= docs.length * 4) {
    return ('프로젝트', topic, '노트 ${docs.length}개 중 $mentions개의 제목에 "$topic"');
  }
  return ('개발 지식', topic, '기본: 다시 쓸 기술·해결법으로 봄');
}

/// 노트가 [topicSplitLimit]개를 넘는 주제 (주제 경로 → 노트 수). 앱이 나누자고 제안한다 (설계서_프롬프트이후 5.1).
/// 합쳐진(옛) 노트는 세지 않는다.
Map<String, int> oversizedTopics(SearchIndex index) {
  final counts = <String, int>{};
  for (final d in index.notes()) {
    if (d.isMerged) continue;
    counts.update(d.topicPath, (n) => n + 1, ifAbsent: () => 1);
  }
  return {
    for (final e in counts.entries)
      if (e.value > topicSplitLimit) e.key: e.value,
  };
}
