import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'neural_layout.dart';

/// 신경망 보기에 넣을 노트 한 개 (색인에서 읽은 값). 출처는 색인에 없어 파일 머리말에서 읽는다.
typedef NeuralNoteRow = ({String id, String path, String title, String topic, bool isDraft});

/// 지식 폴더에서 노트 `sources:`와 원본 제목을 읽어 층 배치까지 한다 (설계서_프롬프트이후 5.3).
/// 파일을 1만 개 읽으므로 화면 스레드에서 부르지 않는다 — 앱은 isolate에서 부른다 (L-0004).
/// 읽지 못한 파일은 출처 없는 노트로 둔다 (지워지는 중인 노트 하나 때문에 화면 전체가 실패하지 않게).
///
/// [rawDocs]는 색인의 원본 문서(경로 → id·제목)다. 있으면 원본 파일을 열지 않는다. 가져온 문서는 머리말에
/// id가 없어 색인 id로만 열 수 있다. 색인에도 없고 지식 폴더 안 보통 파일로도 없는 원본은 입력층에 넣지 않는다:
/// 눌러도 열 것이 없는 점이 생긴다 (11/13 검토). 선은 모두 실제 관계라는 원칙과도 같다.
NeuralLayout neuralLayoutFromVault(
  String vaultRoot,
  List<NeuralNoteRow> notes,
  List<(String, String)> links, {
  Map<String, ({String id, String title})> rawDocs = const {},
  List<List<String>>? sources,
}) {
  final read = sources ?? readNoteSources(vaultRoot, [for (final n in notes) n.path]);
  final reader = _VaultReader(vaultRoot);
  final titles = <String, String>{};
  final rawIds = <String, String>{};
  final missing = <String>{};
  for (final path in {
    for (final list in read)
      for (final source in list) ?neuralInputOf(source)?.path,
  }) {
    final known = rawDocs[path];
    if (known != null) {
      titles[path] = neuralInputTitle(known.title);
      rawIds[path] = known.id;
      continue;
    }
    final head = reader.head(path);
    if (head == null) {
      missing.add(path);
      continue;
    }
    final title = frontmatterScalar(head, 'title');
    if (title != null && title.isNotEmpty) titles[path] = neuralInputTitle(title);
    final id = frontmatterScalar(head, 'id');
    if (id != null && id.isNotEmpty) rawIds[path] = id;
  }
  final specs = [
    for (var i = 0; i < notes.length; i++)
      NeuralNoteSpec(
        id: notes[i].id,
        title: notes[i].title,
        topic: notes[i].topic,
        isDraft: notes[i].isDraft,
        sources: missing.isEmpty
            ? read[i]
            : [
                for (final s in read[i])
                  if (!missing.contains(neuralInputOf(s)?.path)) s,
              ],
      ),
  ];
  return layoutNeural(specs, links, inputTitles: titles, inputRawIds: rawIds);
}

/// 노트 파일들의 `sources:` ([paths]는 지식 폴더 기준, 같은 순서로 돌려준다). 파일 열기가 대부분이라
/// 앱은 노트를 몇 덩어리로 나눠 여러 isolate에서 함께 부른다 (1만 개 약 0.3초 → 나눠서 줄임).
List<List<String>> readNoteSources(String vaultRoot, List<String> paths) {
  final reader = _VaultReader(vaultRoot);
  return [for (final path in paths) frontmatterList(reader.head(path) ?? '', 'sources')];
}

/// 머리말을 읽는 최대 크기. 머리말이 4KB보다 길면(드묾) 이만큼까지만 더 읽는다 (큰 파일 하나가 1만 개 읽기를 막지 않게).
const neuralReadLimit = 256 * 1024;

/// 지식 폴더 안의 보통 파일만 읽는다 (설계서_프롬프트이후 5.3, 11/13 검토).
/// 머리말의 경로는 사람·AI가 쓴 글이라 믿지 않는다: `..`·심볼릭 링크로 지식 폴더 밖을 가리키면 읽지 않고,
/// FIFO·장치 파일은 열면 isolate가 영영 멈출 수 있어 보통 파일(regular file)만 연다.
class _VaultReader {
  _VaultReader(String vaultRoot) : _root = _resolve(vaultRoot) ?? p.normalize(p.absolute(vaultRoot));

  final String _root;

  static String? _resolve(String dir) {
    try {
      return Directory(dir).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }

  /// 폴더 → 심볼릭 링크를 푼 실제 경로 (노트 1만 개라도 폴더는 주제 수만큼이라 한 번씩만 푼다).
  final _dirs = <String, String?>{};

  /// 파일 앞부분. 읽을 수 없거나 지식 폴더 밖·보통 파일이 아니면 null.
  String? head(String relative) {
    final joined = p.normalize(p.join(_root, relative));
    if (!p.isWithin(_root, joined)) return null;
    try {
      // 심볼릭 링크를 풀어도 지식 폴더 안이어야 한다. 파일마다 경로 전체를 풀면 1만 개에서 약 0.15초 늘어
      // (M8), 폴더는 한 번씩만 풀고 파일은 lstat 한 번으로 본다. 파일 자체가 링크면 그것만 따로 푼다.
      final dir = _dirs.putIfAbsent(p.dirname(joined), () => _resolve(p.dirname(joined)));
      if (dir == null || !(dir == _root || p.isWithin(_root, dir))) return null;
      var real = p.join(dir, p.basename(joined));
      var type = FileSystemEntity.typeSync(real, followLinks: false);
      if (type == FileSystemEntityType.link) {
        real = File(real).resolveSymbolicLinksSync();
        if (!p.isWithin(_root, real)) return null;
        type = FileSystemEntity.typeSync(real, followLinks: false);
      }
      // FIFO·장치 파일 등은 열지 않는다 (보통 파일만)
      if (type != FileSystemEntityType.file) return null;
      final handle = File(real).openSync();
      try {
        final first = handle.readSync(4096);
        final head = utf8.decode(first, allowMalformed: true);
        if (first.length < 4096 || !head.startsWith('---') || _frontmatter.hasMatch(head)) return head;
        final rest = handle.readSync(neuralReadLimit - first.length);
        return utf8.decode([...first, ...rest], allowMalformed: true);
      } finally {
        handle.closeSync();
      }
    } on FileSystemException {
      return null;
    }
  }
}

final _frontmatter = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---');
final _item = RegExp(r'^\s*-\s+(.*)$');

/// 머리말 블록 (없으면 null).
String? _block(String text) => _frontmatter.firstMatch(text)?.group(1);

/// 머리말의 목록 값. `key: ["a", "b"]`(앱이 쓰는 모양)와 여러 줄 `- a` 모두 읽는다.
/// YAML 전체를 풀면 1만 개에서 느려 이 키 한 줄만 본다. 모르는 모양이면 그 줄만 YAML로 푼다.
List<String> frontmatterList(String text, String key) {
  final block = _block(text);
  if (block == null) return const [];
  final lines = block.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimRight();
    if (!line.startsWith('$key:')) continue;
    final value = line.substring(key.length + 1).trim();
    if (value.isEmpty) {
      // 여러 줄 목록: 다음 키(들여쓰기 없는 줄)가 나오기 전까지의 `- 항목`
      final out = <String>[];
      for (var j = i + 1; j < lines.length; j++) {
        final m = _item.firstMatch(lines[j]);
        if (m == null) {
          if (lines[j].trim().isEmpty) continue;
          break;
        }
        out.add(_unquote(m.group(1)!.trim()));
      }
      return out;
    }
    if (value.startsWith('[')) {
      try {
        final list = jsonDecode(value);
        if (list is List) return [for (final x in list) '$x'];
      } on FormatException {
        // 따옴표 없는 [a, b] — 아래 YAML로
      }
    }
    try {
      final yaml = loadYaml(value);
      if (yaml is YamlList) return [for (final x in yaml) '$x'];
      if (yaml != null) return ['$yaml'];
    } on YamlException {
      return const [];
    }
    return const [];
  }
  return const [];
}

/// 머리말의 한 값 (`title: "세션 x 사이드 채팅"` → `세션 x 사이드 채팅`).
String? frontmatterScalar(String text, String key) {
  final block = _block(text);
  if (block == null) return null;
  for (final raw in block.split('\n')) {
    final line = raw.trimRight();
    if (line.startsWith('$key:')) return _unquote(line.substring(key.length + 1).trim());
  }
  return null;
}

String _unquote(String v) {
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
    try {
      return jsonDecode(v) as String;
    } on FormatException {
      return v.substring(1, v.length - 1);
    }
  }
  if (v.length >= 2 && v.startsWith("'") && v.endsWith("'")) return v.substring(1, v.length - 1).replaceAll("''", "'");
  return v;
}
