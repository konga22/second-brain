import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../note/zones.dart';
import '../text/nfc.dart';
import 'vault.dart';

/// AI에게 보여 주는 목차 (설계서_프롬프트이후 5.11): 정리된 노트의 번호와 제목을 구역/주제로 묶은 글.
///
/// AI는 지식 폴더에 무엇이 있는지 모르는 채 검색어를 짐작한다. 검색은 글자가 같아야 찾히므로, 요청은 만들 대상을
/// 말하고 노트는 진행 방식을 말하면 놓친다(11/14 응모 세션). 제목 목록을 보여 주면 AI가 뜻으로 고른다 —
/// 있는지도 모르는 노트의 낱말을 맞히기보다 목록에서 알아보기가 쉽다. 교수님 방식(`index.md` → 섹션 목차 → 페이지)에서
/// 가져왔고, 임베딩은 쓰지 않는다.
///
/// - 전체·구역: 제목만. [budget]자를 넘으면 접는다 — 다른 프로젝트 → 생활·기기 → 나머지 순서로 제목을 줄이고,
///   접힌 주제는 `…외 N개 (태그: a, b) → brain toc "구역/주제"` 한 줄로 남는다.
/// - 주제 하나: 제목 + 요약 (교수님 방식의 섹션 목차).
/// - 확인 전 초안과 합쳐진 노트는 뺀다 (4.1: 초안은 AI의 근거가 아니다).
///
/// 같은 지식 폴더면 늘 같은 글이 나온다(시각·세션 id 없음). 그래도 세션 시작 안내에는 넣지 않는다 —
/// 노트가 늘 때마다 글이 달라져 세션 간 캐시가 깨진다(n_0040).
class VaultToc {
  VaultToc(this.index);

  final SearchIndex index;

  /// 목차 최대 글자 수 (사용자 결정 11/14). 지금 지식 폴더(정리된 노트 94개)는 약 3,800자, 약 200개까지 전부 보인다.
  static const defaultBudget = 8000;

  /// 제목은 한 줄로 펴고 이 길이에서 자른다 (실제 폴더 가장 긴 제목 57자).
  static const titleMax = 60;

  /// 주제 하나를 열 때 요약 길이.
  static const summaryMax = 60;

  /// 다른 프로젝트에서도 다시 쓰는 지식 구역 (자리 규칙, 5.1). 접을 때 끝까지 펼쳐 둔다.
  static const reusableZones = {'개발 지식', '조사·참고', '공부'};

  static const _projectZone = '프로젝트';
  static const _lifeZone = '생활·기기';

  /// 목차에 넣을 노트 (최근 고친 것부터). [includeDrafts]는 이전 방식(4.1 전)에서만 쓴다.
  List<IndexedDoc> notes({bool includeDrafts = false, List<IndexedDoc>? docs}) => [
    for (final d in docs ?? index.notes())
      if (d.kind == 'note' && !d.isMerged && (includeDrafts || !d.isDraft)) d,
  ];

  /// 목차 글. [scope]가 없으면 전체, 구역 이름이면 그 구역, `구역/주제`나 주제 이름이면 그 주제(제목 + 요약).
  /// [keepTopic]은 지금 작업 폴더의 프로젝트 주제(`프로젝트/<이름>`) — 접을 때 끝까지 펼쳐 둔다.
  /// 맞는 범위가 없으면 [TocText.notes]가 0이다. [docs]는 부르는 쪽이 이미 읽은 노트 목록([SearchIndex.notes])을 다시 읽지 않게 준다.
  TocText render({String? scope, int budget = defaultBudget, String? keepTopic, bool includeDrafts = false, List<IndexedDoc>? docs}) {
    final all = notes(includeDrafts: includeDrafts, docs: docs);
    final groups = <String, List<IndexedDoc>>{};
    for (final doc in all) {
      groups.putIfAbsent(doc.topicPath, () => []).add(doc);
    }
    var topics = _ordered(groups);
    if (scope != null && scope.trim().isNotEmpty) {
      final wanted = _key(scope);
      if (isZone(scope)) {
        topics = [for (final t in topics) if (_key(t.split('/').first) == wanted && t.contains('/')) t];
      } else {
        // `구역/주제` 그대로, 또는 주제 이름만(구역이 달라도 같은 이름이면 모두). 띄어쓰기·대소문자는 가리지 않는다.
        topics = [for (final t in topics) if (_key(t) == wanted || _key(t.split('/').last) == wanted) t];
      }
      if (topics.length == 1) return _topic(topics.single, groups[topics.single]!, budget);
    }
    final count = topics.fold(0, (n, t) => n + groups[t]!.length);
    if (topics.isEmpty) return const TocText(text: '', notes: 0, shown: 0, topics: 0);
    final (text, shown) = _titles(topics, groups, budget, keepTopic: keepTopic);
    return TocText(text: text, notes: count, shown: shown, topics: topics.length);
  }

  /// 구역 순서(프로젝트, 개발 지식, …), 구역 밖 예전 주제는 뒤. 같은 구역 안은 노트 많은 주제부터, 같으면 이름순.
  static List<String> _ordered(Map<String, List<IndexedDoc>> groups) {
    int zoneRank(String topic) {
      final at = noteZones.indexOf(topic.split('/').first);
      return topic.contains('/') && at >= 0 ? at : noteZones.length;
    }

    return groups.keys.toList()..sort((a, b) {
      final zone = zoneRank(a).compareTo(zoneRank(b));
      if (zone != 0) return zone;
      final size = groups[b]!.length.compareTo(groups[a]!.length);
      return size != 0 ? size : a.compareTo(b);
    });
  }

  /// 띄어쓰기·대소문자만 다른 이름은 같은 것으로 본다 (`brain add --topic`과 같은 기준).
  static String _key(String name) => toNfc(name).toLowerCase().replaceAll(RegExp(r'\s+'), '');

  static String _flat(String text, int max) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final runes = flat.runes.toList();
    return runes.length <= max ? flat : '${String.fromCharCodes(runes.take(max))}…';
  }

  static String _titleLine(IndexedDoc doc) => '${doc.id} ${doc.isDraft ? '[초안] ' : ''}${_flat(doc.title, titleMax)}';

  /// 접힌 노트가 무엇인지 짐작할 단서: 그 주제에서 가장 자주 쓰인 태그 3개 (주제 이름과 같은 태그는 뺀다).
  /// 큰 주제는 최근 고친 300개만 센다 (단서일 뿐이라 정확한 수가 필요 없다).
  static String _tagHint(String topic, List<IndexedDoc> docs) {
    final own = _key(topic.split('/').last);
    final counts = <String, int>{};
    for (final doc in docs.take(300)) {
      for (final tag in doc.tags.split(',')) {
        final name = tag.trim();
        if (name.isEmpty || _key(name) == own) continue;
        counts.update(name, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final top = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return top.isEmpty ? '' : ' (태그: ${top.take(3).map((t) => _flat(t, 12)).join(', ')})';
  }

  /// 접을 때 제목을 채우는 순서: 지금 프로젝트 → 다시 쓸 지식 구역·구역 밖 주제 → 생활·기기 → 다른 프로젝트.
  static int _tier(String topic, String? keepTopic) {
    if (keepTopic != null && _key(topic) == _key(keepTopic)) return 0;
    final zone = topic.contains('/') ? topic.split('/').first : '';
    if (zone == _projectZone) return 3;
    if (zone == _lifeZone) return 2;
    return 1;
  }

  /// 제목 목록. 다 들어가면 전부, 넘으면 순서대로 채우고 나머지는 접는다. (글, 제목이 보인 노트 수)
  ///
  /// 제목 줄과 태그 단서는 보일 것만 만든다: 노트 1만 개에서 줄 1만 개를 다 만들면 훅이 100ms 목표(6.2)를 넘었다(11/14 129ms).
  (String, int) _titles(List<String> topics, Map<String, List<IndexedDoc>> groups, int budget, {String? keepTopic}) {
    final sizes = {for (final t in topics) t: groups[t]!.length};
    final lines = {for (final t in topics) t: <String>[]};
    final sums = {for (final t in topics) t: <int>[0]}; // sums[t][k] = 앞 k줄의 (길이 + 줄바꿈) 합
    int sum(String t, int k) {
      final made = lines[t]!;
      final acc = sums[t]!;
      while (acc.length <= k) {
        final line = _titleLine(groups[t]![made.length]);
        made.add(line);
        acc.add(acc.last + line.length + 1);
      }
      return acc[k];
    }

    final hints = <String, String>{};
    String hint(String t) => hints[t] ??= _tagHint(t, groups[t]!);
    String tail(String t, int k) => '…외 ${sizes[t]! - k}개${hint(t)} → brain toc "$t"';
    String folded(String t) => '[$t] 노트 ${sizes[t]}개${hint(t)} → brain toc "$t"';
    // 주제 [t]의 제목을 [k]개 보일 때 그 덩어리의 길이 (줄마다 줄바꿈 1자 포함).
    int length(String t, int k) {
      if (k == 0) return folded(t).length + 1;
      return t.length + 3 + sum(t, k) + (k < sizes[t]! ? tail(t, k).length + 1 : 0);
    }

    final shown = {for (final t in topics) t: 0};
    // 제목 한 줄은 번호만으로도 8자다: 그것만으로 상한을 넘으면 전부 펼친 길이는 재지 않는다.
    var fits = sizes.values.fold(0, (n, size) => n + size) * 8 <= budget;
    if (fits) {
      fits = topics.fold(0, (n, t) => n + length(t, sizes[t]!)) <= budget;
      if (fits) shown.updateAll((t, _) => sizes[t]!);
    }
    if (!fits) {
      var total = topics.fold(0, (n, t) => n + length(t, 0));
      if (total > budget) return (_zones(topics, groups, budget), 0);
      // 순서대로, 같은 순서 안에서는 주제마다 한 줄씩 돌아가며(최근 고친 것부터) 채운다.
      for (var tier = 0; tier <= 3; tier++) {
        final members = [for (final t in topics) if (_tier(t, keepTopic) == tier) t];
        var progressed = true;
        while (progressed) {
          progressed = false;
          for (final t in members) {
            final k = shown[t]!;
            if (k >= sizes[t]!) continue;
            final next = total - length(t, k) + length(t, k + 1);
            if (next > budget) continue;
            shown[t] = k + 1;
            total = next;
            progressed = true;
          }
        }
      }
    }
    final out = <String>[];
    for (final t in topics) {
      final k = shown[t]!;
      if (k == 0) {
        out.add(folded(t));
        continue;
      }
      sum(t, k);
      out
        ..add('[$t]')
        ..addAll(lines[t]!.take(k));
      if (k < sizes[t]!) out.add(tail(t, k));
    }
    return (out.join('\n'), shown.values.fold(0, (n, k) => n + k));
  }

  /// 주제 이름 줄조차 다 못 넣을 만큼 클 때: 구역마다 주제 이름과 노트 수만 (많은 주제부터). AI가 한 단계씩 내려가 본다.
  String _zones(List<String> topics, Map<String, List<IndexedDoc>> groups, int budget) {
    final byZone = <String, List<String>>{};
    for (final t in topics) {
      byZone.putIfAbsent(t.contains('/') ? t.split('/').first : '구역 밖', () => []).add(t);
    }
    final each = (budget ~/ byZone.length).clamp(80, budget);
    final out = <String>[];
    for (final MapEntry(key: zone, value: members) in byZone.entries) {
      final count = members.fold(0, (n, t) => n + groups[t]!.length);
      final head = '[$zone] 주제 ${members.length}개·노트 $count개: ';
      final tail = zone == '구역 밖' ? ' → brain toc "<주제>"' : ' → brain toc "$zone/<주제>"';
      final names = StringBuffer();
      var listed = 0;
      for (final t in members) {
        final name = '${t.split('/').last}(${groups[t]!.length})';
        if (head.length + names.length + name.length + tail.length + 12 > each) break;
        if (listed > 0) names.write(', ');
        names.write(name);
        listed++;
      }
      final more = members.length - listed;
      out.add('$head$names${more > 0 ? ' …외 $more개(brain topics)' : ''}$tail');
    }
    if (out.join('\n').length <= budget) return out.join('\n');
    // 상한이 아주 작으면 구역 줄도 다 못 넣는다: 들어가는 줄까지만 두고 나머지는 한 줄로 알린다 (상한은 늘 지킨다).
    const rest = '…(나머지 구역은 brain topics)';
    final kept = <String>[];
    var used = rest.length;
    for (final line in out) {
      if (used + line.length + 1 > budget) break;
      kept.add(line);
      used += line.length + 1;
    }
    return [...kept, rest].join('\n');
  }

  /// 주제 하나: 제목 — 요약. 넘으면 최근 고친 것부터 보이고 나머지는 한 줄로.
  TocText _topic(String topic, List<IndexedDoc> docs, int budget) {
    final out = <String>['[$topic]'];
    var used = out.first.length + 1;
    var shown = 0;
    for (final doc in docs) {
      final summary = doc.summary.trim().isEmpty ? '' : ' — ${_flat(doc.summary, summaryMax)}';
      final line = '${_titleLine(doc)}$summary';
      // 마지막 한 줄("…외 N개")이 들어갈 자리를 남긴다.
      if (used + line.length + 1 > budget - 60 && shown < docs.length - 1) break;
      out.add(line);
      used += line.length + 1;
      shown++;
    }
    if (shown < docs.length) {
      out.add('…외 ${docs.length - shown}개(오래 안 고친 것) → brain find <검색어> --topic "$topic"');
    }
    return TocText(text: out.join('\n'), notes: docs.length, shown: shown, topics: 1, isTopic: true);
  }
}

/// [VaultToc.render] 결과.
class TocText {
  const TocText({required this.text, required this.notes, required this.shown, required this.topics, this.isTopic = false});

  /// 목차 줄들 (머리말·데이터 표시는 부르는 쪽이 붙인다). 범위에 노트가 없으면 빈 글.
  final String text;

  /// 범위 안 노트 수.
  final int notes;

  /// 제목이 실제로 보인 노트 수 ([notes]보다 작으면 접혔다).
  final int shown;

  final int topics;

  /// 주제 하나를 연 것(제목 + 요약)인가.
  final bool isTopic;

  bool get isEmpty => notes == 0;

  bool get isFolded => shown < notes;
}

/// "이 세션에 목차를 이미 붙였다"를 적어 두는 곳 (설계서_프롬프트이후 5.11).
///
/// 요청 훅은 요청마다 새 프로세스라 앞 요청을 모른다. 만들기 요청마다 목차를 붙이면 긴 세션에서 수만 자가 쌓이므로
/// (지난 요청 1,113개 기준 요청마다 93번 · 세션에 한 번이면 41번) 세션에 한 번만 붙이고 그 뒤에는 한 줄로 가리킨다.
/// 추측하지 않고 적어 둔다: 색인 캐시 폴더 `toc-shown/<세션 id>` 빈 파일(지식 폴더 밖). 14일 지난 파일은 지운다.
/// 세션 id를 모르면 "안 붙였다"로 본다 — 한 번 더 붙는 쪽이 빠지는 쪽보다 안전하다.
class TocShown {
  /// [dir]은 시험에서만 준다. 기본은 그 지식 폴더의 색인 캐시 폴더 안이다.
  TocShown(Vault vault, {String? dir}) : dir = dir ?? p.join(p.dirname(vault.indexPath), 'toc-shown');

  final String dir;

  static const keepFor = Duration(days: 14);

  File? _file(String? sessionId) {
    final id = (sessionId ?? '').replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (id.isEmpty) return null;
    return File(p.join(dir, id.length > 80 ? id.substring(0, 80) : id));
  }

  bool has(String? sessionId) => _file(sessionId)?.existsSync() ?? false;

  /// 붙였다고 적는다. 적지 못해도(디스크 가득 등) 훅은 계속 간다 — 다음 요청에 한 번 더 붙을 뿐이다.
  void mark(String? sessionId) {
    final file = _file(sessionId);
    if (file == null) return;
    try {
      Directory(dir).createSync(recursive: true);
      file.writeAsStringSync('');
      final cutoff = DateTime.now().subtract(keepFor);
      for (final old in Directory(dir).listSync().whereType<File>()) {
        if (old.statSync().modified.isBefore(cutoff)) old.deleteSync();
      }
    } on FileSystemException {
      // 못 적으면 그대로 둔다
    }
  }

  /// 압축·`/clear` 뒤에는 목차가 맥락에서 사라졌으니 다음 만들기 요청에 다시 붙게 한다.
  void clear(String? sessionId) {
    try {
      final file = _file(sessionId);
      if (file != null && file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // 못 지우면 한 줄 안내만 간다 — AI가 brain toc로 다시 볼 수 있다
    }
  }
}
