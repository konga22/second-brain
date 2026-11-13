import 'dart:typed_data';

/// 신경망 보기 층 배치 (설계서_프롬프트이후 5.3).
///
/// 입력층(대화·가져온 문서) → 은닉층(노트) → 출력층(주제). 선은 모두 실제 관계다:
/// 노트 `sources:`의 원본 → 노트, 노트 → 자기 주제(진하게), 노트 → `[[링크]]` 이웃의 주제(흐린 점선).
/// 위치(px)는 화면이 정한다. 여기서는 층마다 위에서 아래로의 **순서**만 정한다 — 순서가 곧 자리라서
/// 선이 덜 엉키는 순서를 고르는 것이 이 파일의 일이다. 화면 없이 도는 순수 Dart다 (isolate에서 부른다, L-0004).

/// 입력층 노드 종류 (5.3 결정 1): 대화는 동그라미, 가져온 문서는 마름모.
enum NeuralInputKind { session, document }

/// 배치에 넣는 노트 한 개. isolate로 넘기므로 단순 값만 둔다.
class NeuralNoteSpec {
  const NeuralNoteSpec({
    required this.id,
    required this.title,
    required this.topic,
    this.isDraft = false,
    this.sources = const [],
  });

  final String id;
  final String title;

  /// 주제 묶음 이름. 화면 쪽이 `IndexedDoc.topicPath`(구역/주제)로 넘긴다 (폴더 구조는 여기서 풀지 않는다).
  final String topic;
  final bool isDraft;

  /// 노트 머리말 `sources:` 그대로. 입력층이 아닌 경로(`*.jsonl` 등)는 배치가 걸러 낸다.
  final List<String> sources;
}

/// 입력층 노드 하나 (화면 순서대로).
class NeuralInput {
  const NeuralInput({
    required this.path,
    required this.title,
    required this.kind,
    required this.date,
    required this.notes,
    this.rawId,
  });

  /// `raw/sessions/2026-10-02-bed8445f.md` 처럼 지식 폴더 기준 경로.
  final String path;
  final String title;
  final NeuralInputKind kind;

  /// 경로에 든 날짜 (`2026-10-02`). 없으면 빈 글자.
  final String date;

  /// 이 원본에서 나온 노트 (은닉층 순서 번호).
  final Int32List notes;

  /// 원본 문서가 색인에 있으면 그 id (`r_bed8445f`). 누르면 오른쪽 패널에 연다.
  final String? rawId;
}

/// 은닉층 노드 하나 (화면 순서대로).
class NeuralNote {
  const NeuralNote({
    required this.id,
    required this.title,
    required this.topic,
    required this.isDraft,
    required this.inputs,
    required this.neighborTopics,
  });

  final String id;
  final String title;

  /// 자기 주제 (출력층 순서 번호).
  final int topic;
  final bool isDraft;

  /// 나온 원본 (입력층 순서 번호, 중복 없음).
  final Int32List inputs;

  /// 링크로 이어진 이웃 노트의 주제 가운데 자기 주제가 아닌 것 (출력층 순서 번호, 중복 없음).
  final Int32List neighborTopics;
}

/// 출력층 노드 하나. 같은 주제 노트는 은닉층에서 [start]부터 [count]개가 붙어 있다.
class NeuralTopic {
  const NeuralTopic({required this.name, required this.start, required this.count});

  final String name;
  final int start;
  final int count;
}

/// 두 구간의 선 겹침 수.
class NeuralCrossings {
  const NeuralCrossings(this.inputNote, this.noteTopic);

  /// 대화 → 노트 구간.
  final int inputNote;

  /// 노트 → 주제 구간 (진한 선 + 흐린 선).
  final int noteTopic;

  int get total => inputNote + noteTopic;
}

class NeuralLayout {
  NeuralLayout({
    required this.inputs,
    required this.notes,
    required this.topics,
    required this.naive,
    required this.crossings,
  });

  static final empty = NeuralLayout(
    inputs: const [],
    notes: const [],
    topics: const [],
    naive: const NeuralCrossings(0, 0),
    crossings: const NeuralCrossings(0, 0),
  );

  final List<NeuralInput> inputs;
  final List<NeuralNote> notes;
  final List<NeuralTopic> topics;

  /// 정리 전 순서(대화 날짜순·노트 받은 순·주제 이름순)의 겹침.
  final NeuralCrossings naive;

  /// 고른 순서의 겹침.
  final NeuralCrossings crossings;

  int get sourceEdgeCount => notes.fold(0, (s, n) => s + n.inputs.length);
  int get faintEdgeCount => notes.fold(0, (s, n) => s + n.neighborTopics.length);

  late final Map<String, int> _noteIndex = {for (var i = 0; i < notes.length; i++) notes[i].id: i};
  late final Map<String, int> _rawIndex = {
    for (var i = 0; i < inputs.length; i++)
      if (inputs[i].rawId != null) inputs[i].rawId!: i,
  };

  /// 노트 id → 은닉층 순서 번호.
  int? indexOfNote(String id) => _noteIndex[id];

  /// 원본 문서 id(`r_…`) → 입력층 순서 번호.
  int? indexOfRaw(String id) => _rawIndex[id];
}

final _inputPath = RegExp(r'(?:^|/)(raw/(sessions|imports)/.+)$');
final _datePart = RegExp(r'\d{4}-\d{2}-\d{2}');

/// `sources:`의 한 경로를 입력층 경로로 바꾼다. 대화(`raw/sessions/`)·가져온 문서(`raw/imports/`)가 아니면 null.
({String path, NeuralInputKind kind})? neuralInputOf(String source) {
  final m = _inputPath.firstMatch(source.replaceAll(r'\', '/'));
  if (m == null) return null;
  return (path: m.group(1)!, kind: m.group(2) == 'sessions' ? NeuralInputKind.session : NeuralInputKind.document);
}

/// 원본 제목 `세션 bed8445f 사이드 채팅` → `사이드 채팅` (세션 id는 이름표에서 읽을 수 없는 글자라 뺀다).
String neuralInputTitle(String rawTitle) {
  final t = rawTitle.replaceFirst(RegExp(r'^세션 \S+ ?'), '').trim();
  return t.isEmpty ? rawTitle.trim() : t;
}

/// 층 배치. [links]는 직접 연결(`[[ ]]`)만 넘긴다 (추천 연결은 실제 관계가 아니다).
/// [inputTitles]·[inputRawIds]는 입력 경로 → 원본 제목·id (없으면 파일 이름).
NeuralLayout layoutNeural(
  List<NeuralNoteSpec> specs,
  List<(String, String)> links, {
  Map<String, String> inputTitles = const {},
  Map<String, String> inputRawIds = const {},
  int iterations = 8,
}) {
  if (specs.isEmpty) return NeuralLayout.empty;
  final nN = specs.length;

  // 1. 색인 모형: 입력·주제를 번호로 바꾼다.
  final inputIndex = <String, int>{};
  final inputPaths = <String>[];
  final inputKinds = <NeuralInputKind>[];
  final topicIndex = <String, int>{};
  final topicNames = <String>[];
  final noteIndex = <String, int>{};
  final noteTopic = Int32List(nN);
  final noteInputs = List<List<int>>.filled(nN, const []);
  for (var i = 0; i < nN; i++) {
    final s = specs[i];
    noteIndex.putIfAbsent(s.id, () => i);
    noteTopic[i] = topicIndex.putIfAbsent(s.topic, () {
      topicNames.add(s.topic);
      return topicNames.length - 1;
    });
    final own = <int>[];
    for (final source in s.sources) {
      final input = neuralInputOf(source);
      if (input == null) continue;
      final at = inputIndex.putIfAbsent(input.path, () {
        inputPaths.add(input.path);
        inputKinds.add(input.kind);
        return inputPaths.length - 1;
      });
      if (!own.contains(at)) own.add(at);
    }
    noteInputs[i] = own;
  }
  final nI = inputPaths.length;
  final nT = topicNames.length;

  // 흐린 선: 링크로 이어진 이웃 노트의 주제 (자기 주제는 빼고, 중복 없이).
  final neighborTopics = List<List<int>>.generate(nN, (_) => <int>[]);
  for (final (a, b) in links) {
    final ia = noteIndex[a], ib = noteIndex[b];
    if (ia == null || ib == null || ia == ib) continue;
    void add(int from, int to) {
      final t = noteTopic[to];
      if (t != noteTopic[from] && !neighborTopics[from].contains(t)) neighborTopics[from].add(t);
    }

    add(ia, ib);
    add(ib, ia);
  }
  final inputNotes = List<List<int>>.generate(nI, (_) => <int>[]);
  final topicNotes = List<List<int>>.generate(nT, (_) => <int>[]);
  for (var i = 0; i < nN; i++) {
    for (final x in noteInputs[i]) {
      inputNotes[x].add(i);
    }
    topicNotes[noteTopic[i]].add(i);
  }
  final inputDates = [for (final path in inputPaths) _datePart.firstMatch(path.split('/').last)?.group(0) ?? ''];

  // 2. 정리 전 순서: 대화는 날짜순, 노트는 받은 순, 주제는 이름순.
  Int32List rankOf(List<int> order) {
    final r = Int32List(order.length);
    for (var i = 0; i < order.length; i++) {
      r[order[i]] = i;
    }
    return r;
  }

  NeuralCrossings crossingsFor(Int32List inRank, Int32List noteRank, Int32List topicRank) {
    final au = <int>[], av = <int>[], bu = <int>[], bv = <int>[];
    for (var i = 0; i < nN; i++) {
      for (final x in noteInputs[i]) {
        au.add(inRank[x]);
        av.add(noteRank[i]);
      }
      bu.add(noteRank[i]);
      bv.add(topicRank[noteTopic[i]]);
      for (final t in neighborTopics[i]) {
        bu.add(noteRank[i]);
        bv.add(topicRank[t]);
      }
    }
    return NeuralCrossings(countLayerCrossings(au, av, nN), countLayerCrossings(bu, bv, nT));
  }

  final dateOrder = List<int>.generate(nI, (i) => i)
    ..sort((a, b) {
      // 날짜 없는 경로는 뒤로
      final da = inputDates[a].isEmpty ? '9999' : inputDates[a];
      final db = inputDates[b].isEmpty ? '9999' : inputDates[b];
      final c = da.compareTo(db);
      return c != 0 ? c : inputPaths[a].compareTo(inputPaths[b]);
    });
  final nameOrder = List<int>.generate(nT, (i) => i)..sort((a, b) => topicNames[a].compareTo(topicNames[b]));
  final naive = crossingsFor(rankOf(dateOrder), rankOf(List<int>.generate(nN, (i) => i)), rankOf(nameOrder));

  // 3. 순서 고르기: 같은 주제 노트는 붙여 두고(칸 나눔 없음), 주제 안에서는 나온 대화 위치 순.
  //    대화·주제 순서는 무게중심(barycenter)으로 몇 번 되풀이해 겹침이 가장 적은 것을 고른다 (시안과 같은 방법).
  var inOrder = dateOrder;
  var topicOrder = nameOrder;
  ({int total, NeuralCrossings c, List<int> inOrder, List<int> topicOrder, List<int> noteOrder})? best;
  final noteKey = Float64List(nN);
  for (var iter = 0; iter < iterations; iter++) {
    final inRank = rankOf(inOrder), tRank = rankOf(topicOrder);
    for (var i = 0; i < nN; i++) {
      final src = noteInputs[i];
      if (src.isEmpty) {
        noteKey[i] = nI.toDouble(); // 출처 없는 노트는 주제 묶음 끝
      } else {
        var s = 0;
        for (final x in src) {
          s += inRank[x];
        }
        noteKey[i] = s / src.length;
      }
    }
    final noteOrder = List<int>.generate(nN, (i) => i)
      ..sort((a, b) {
        final t = tRank[noteTopic[a]] - tRank[noteTopic[b]];
        if (t != 0) return t;
        final k = noteKey[a].compareTo(noteKey[b]);
        if (k != 0) return k;
        final c = specs[a].title.compareTo(specs[b].title);
        return c != 0 ? c : specs[a].id.compareTo(specs[b].id);
      });
    final nRank = rankOf(noteOrder);
    final c = crossingsFor(inRank, nRank, tRank);
    if (best == null || c.total < best.total) {
      best = (total: c.total, c: c, inOrder: inOrder, topicOrder: topicOrder, noteOrder: noteOrder);
    }
    // 대화: 자기 노트 위치의 평균으로 다시 줄 세움
    final inKey = Float64List(nI);
    for (var x = 0; x < nI; x++) {
      final ns = inputNotes[x];
      var s = 0;
      for (final j in ns) {
        s += nRank[j];
      }
      inKey[x] = ns.isEmpty ? inRank[x] * nN / nI : s / ns.length;
    }
    inOrder = List<int>.generate(nI, (i) => i)
      ..sort((a, b) {
        final k = inKey[a].compareTo(inKey[b]);
        return k != 0 ? k : inRank[a] - inRank[b];
      });
    // 주제: 소속 노트가 나온 대화의 평균 위치
    final inRank2 = rankOf(inOrder);
    final tKey = Float64List(nT);
    for (var t = 0; t < nT; t++) {
      var s = 0, c2 = 0;
      for (final j in topicNotes[t]) {
        for (final x in noteInputs[j]) {
          s += inRank2[x];
          c2++;
        }
      }
      tKey[t] = c2 > 0 ? s / c2 : nI / 2 + t * 1e-3;
    }
    topicOrder = List<int>.generate(nT, (i) => i)
      ..sort((a, b) {
        final k = tKey[a].compareTo(tKey[b]);
        return k != 0 ? k : topicNames[a].compareTo(topicNames[b]);
      });
  }
  final chosen = best!;

  // 4. 화면 순서로 다시 번호를 매겨 내보낸다.
  final inRank = rankOf(chosen.inOrder), tRank = rankOf(chosen.topicOrder), nRank = rankOf(chosen.noteOrder);
  Int32List sortedOf(Iterable<int> xs, Int32List rank) => Int32List.fromList([for (final x in xs) rank[x]]..sort());
  final notes = [
    for (final i in chosen.noteOrder)
      NeuralNote(
        id: specs[i].id,
        title: specs[i].title,
        topic: tRank[noteTopic[i]],
        isDraft: specs[i].isDraft,
        inputs: sortedOf(noteInputs[i], inRank),
        neighborTopics: sortedOf(neighborTopics[i], tRank),
      ),
  ];
  final inputs = [
    for (final x in chosen.inOrder)
      NeuralInput(
        path: inputPaths[x],
        title: inputTitles[inputPaths[x]] ?? inputPaths[x].split('/').last.replaceFirst(RegExp(r'\.md$'), ''),
        kind: inputKinds[x],
        date: inputDates[x],
        notes: sortedOf(inputNotes[x], nRank),
        rawId: inputRawIds[inputPaths[x]],
      ),
  ];
  final topics = <NeuralTopic>[];
  var start = 0;
  for (final t in chosen.topicOrder) {
    topics.add(NeuralTopic(name: topicNames[t], start: start, count: topicNotes[t].length));
    start += topicNotes[t].length;
  }
  return NeuralLayout(inputs: inputs, notes: notes, topics: topics, naive: naive, crossings: chosen.c);
}

/// 두 층 사이 선 겹침 수. 선 i는 위층 순위 [u]\[i] → 아래층 순위 [v]\[i] ([vSize]는 아래층 크기).
/// (u, v) 순으로 정렬한 뒤 v의 역전 수를 펜윅 트리로 센다 — O(E log V). 끝을 나누는 선은 겹침이 아니다.
int countLayerCrossings(List<int> u, List<int> v, int vSize) {
  final n = u.length;
  if (n < 2) return 0;
  final w = vSize + 1;
  final keys = Int64List(n);
  for (var i = 0; i < n; i++) {
    keys[i] = u[i] * w + v[i];
  }
  keys.sort();
  final bit = Int32List(vSize + 2);
  var cross = 0, seen = 0;
  for (var i = 0; i < n; i++) {
    final vi = keys[i] % w;
    var le = 0; // 지금까지 본 선 가운데 v가 vi 이하인 수
    for (var j = vi + 1; j > 0; j -= j & -j) {
      le += bit[j];
    }
    cross += seen - le;
    for (var j = vi + 1; j <= vSize + 1; j += j & -j) {
      bit[j]++;
    }
    seen++;
  }
  return cross;
}
