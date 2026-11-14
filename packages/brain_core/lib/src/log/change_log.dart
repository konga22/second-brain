import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../note/note.dart';
import '../note/note_assets.dart';
import '../sessions/session_registry.dart';
import '../vault/vault.dart';

/// 작업 묶음 id (설계서 5.1). AI 작업 한 번에 바뀐 파일을 같은 묶음으로 남겨 `brain undo`로 되돌린다.
///
/// - `BRAIN_BATCH` 환경변수가 있으면 그 값
/// - 없으면 명령(프로세스) 하나가 한 묶음
/// - 세션에서 저장하는 노트(`--source-session`)는 `s_<세션 앞 8자>`로 묶는다
String get currentBatch => _processBatch ??=
    Platform.environment['BRAIN_BATCH'] ?? newBatchId();

String? _processBatch;

/// 새 묶음 id `b_20261106-213000-a1b2`. 앱은 사용자 동작마다 하나씩 만든다.
String newBatchId() {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final rand = Random().nextInt(0xffff).toRadixString(16).padLeft(4, '0');
  return 'b_${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}-$rand';
}

/// Claude Code가 Bash 도구에 넣는 환경변수로 본 "AI 대화 안에서 부른 명령"인가.
/// `brain add`의 초안 강제(4.1)와 변경 기록의 AI 표시(4.3)가 같은 기준을 쓴다.
bool isAiSessionEnv(Map<String, String> env) =>
    env['CLAUDECODE'] == '1' || (env['CLAUDE_CODE_SESSION_ID'] ?? '').isNotEmpty;

/// 지금 프로세스가 AI 대화 안에서 도는가: null이면 아니고, 빈 문자열이면 대화 id를 모른다.
String? _aiSession;

/// 이 프로세스가 남기는 변경 기록 줄에 AI 대화 표시를 붙인다 (설계서_프롬프트이후 4.3).
/// `brain` CLI만 시작할 때 부른다: 앱을 Claude Code 터미널에서 띄워도 사람의 편집이 AI로 적히지 않게.
/// 예전 기록은 사람·AI 고침이 같은 모양이라 정리 보드가 "AI가 고친 노트"를 가려낼 수 없었다.
void markAiSession(String? sessionId) => _aiSession = sessionId;

/// 변경 기록 줄 끝의 AI 표시: ` · AI` 또는 ` · AI 대화 <세션 id>`.
final aiLogMark = RegExp(r' · AI(?: 대화 (\S+))?$');

/// 변경 기록 내용에서 AI 표시를 뗀다. 기록을 읽어 키·화면 글로 쓰는 곳은 모두 이것을 거친다
/// (설계서_프롬프트이후 4.3, 11/13 검토: 할 일 키·`brain review`에 ` · AI 대화 <id>`가 섞였다).
/// 사람이 쓴 할 일이 마침 " · AI"로 끝나면 AI 표시로 읽힌다 — 기록 모양이 같아 가릴 수 없다.
String stripAiMark(String detail) => detail.replaceFirst(aiLogMark, '');

/// 변경 기록 `_log/YYYY-MM.md`에 한 줄 추가한다 (추가만 함, 설계서 4.1).
void appendChangeLog(
  Vault vault,
  String action,
  String detail, {
  String? batch,
}) {
  final now = DateTime.now();
  final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
  final file = File(p.join(vault.logDir, '$month.md'));
  file.parent.createSync(recursive: true);
  if (!file.existsSync()) file.writeAsStringSync('# 변경 기록 $month\n\n');
  final session = _aiSession;
  final mark = session == null ? '' : (session.isEmpty ? ' · AI' : ' · AI 대화 $session');
  final batchId = batch ?? currentBatch;
  file.writeAsStringSync(
    '- ${formatTime(now)} [$batchId] $action $detail$mark\n',
    mode: FileMode.append,
    flush: true,
  );
  _recordAfterChanges(vault, batchId);
}

/// 묶음별로 바꾸기 전을 남겼지만 "바꾼 뒤" 해시를 아직 적지 않은 파일 (이 프로세스 안, 절대 경로).
final _pendingAfter = <String, Set<String>>{};

/// 파일 내용의 sha1 (없으면 null). 되돌리기 전 확인용이라 노트 해시([contentHash])와 달리 전체 길이를 쓴다.
String? fileHash(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  return sha1.convert(file.readAsBytesSync()).toString();
}

/// 묶음이 바꾼 파일의 "바꾼 뒤" 해시를 `_meta/undo/<묶음>/after.jsonl`에 남긴다 (설계서_프롬프트이후 4.3, 11/13 검토).
///
/// [되돌리기]는 바꾸기 전 사본만 있어 그 뒤 다른 곳(사람·편집기·다른 AI 묶음)에서 고친 내용을 모르고 덮었다.
/// 쓰는 곳마다 따로 부르지 않게, 바꾸기 전을 남긴 파일([recordBeforeChange])을 같은 묶음의 변경 기록 줄을 쓸 때
/// 한꺼번에 적는다 — 노트·실수 노트·할 일 쓰기는 모두 "바꾸기 전 남김 → 쓰기 → 기록 한 줄" 순서다.
/// 추가만 하고 같은 경로는 마지막 줄이 이긴다(`BRAIN_BATCH`로 여러 프로세스가 한 묶음을 써도 맞다).
void _recordAfterChanges(Vault vault, String batch) {
  final paths = _pendingAfter.remove(batch);
  if (paths == null || paths.isEmpty || !batchIdPattern.hasMatch(batch)) return;
  final dir = Directory(p.join(vault.metaDir, 'undo', batch));
  if (!dir.existsSync()) return;
  final lines = [
    for (final path in paths) jsonEncode({'path': p.relative(path, from: vault.root), 'hash': fileHash(path)}),
  ];
  File(p.join(dir.path, 'after.jsonl')).writeAsStringSync('${lines.join('\n')}\n', mode: FileMode.append, flush: true);
}

/// 묶음 하나가 남긴 "바꾼 뒤" 해시: 지식 폴더 기준 경로 → 해시(null = 지운 파일). 예전 묶음에는 없다.
Map<String, String?> _afterHashes(String dir) {
  final file = File(p.join(dir, 'after.jsonl'));
  final out = <String, String?>{};
  if (!file.existsSync()) return out;
  for (final line in file.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      out[json['path'] as String] = json['hash'] as String?;
    } on FormatException {
      continue;
    }
  }
  return out;
}

/// 되돌리면 남의 고침을 덮는 파일 하나. [isUnknown]이면 "바꾼 뒤" 기록이 없는 예전 묶음이라 확인할 수 없다.
typedef BatchDrift = ({String path, bool isUnknown});

/// [batches]를 앞에서부터(최근 것 먼저) 차례로 되돌린다고 할 때, 각 묶음이 바꾼 파일이 그때 그 묶음이 남긴 그대로인지 본다
/// (설계서_프롬프트이후 4.3, 11/13 검토). 파일을 고치지 않는다. 반환이 비었을 때만 되돌려도 다른 고침이 사라지지 않는다.
///
/// 뒤 묶음을 되돌린 뒤의 상태는 그 묶음의 바꾸기 전 사본이므로, 앞 묶음은 그 사본과 견준다.
List<BatchDrift> driftSinceBatches(Vault vault, List<String> batches) {
  final expected = <String, String?>{}; // 경로 → 그 묶음을 되돌리기 직전에 있을 내용의 해시
  final out = <BatchDrift>[];
  for (final batch in batches) {
    final dir = _undoDir(vault, batch);
    final manifest = File(p.join(dir, 'manifest.jsonl'));
    if (!manifest.existsSync()) continue;
    final after = _afterHashes(dir);
    for (final line in manifest.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final entry = _jsonLine(line);
      if (entry == null) continue;
      final rel = entry['path'] as String;
      final now = expected.containsKey(rel) ? expected[rel] : fileHash(p.join(vault.root, rel));
      final isUnknown = !after.containsKey(rel);
      final backup = entry['backup'] as String?;
      final existed = entry['existed'] == true && backup != null;
      final before = existed ? fileHash(p.join(dir, backup)) : null;
      // 이미 바꾸기 전 내용 그대로면 되돌려도 바뀌는 것이 없다. 새로 만든 파일이 없어진 것은 그렇게 보지 않는다 —
      // 그 뒤 다른 묶음이 이름을 바꾸거나 옮겼을 수 있다(되돌리면 아무것도 안 하고 "되돌림"이 된다). 다만 "바꾼 뒤" 기록이
      // 없는 줄(중간에 끊긴 묶음의 마지막 파일)은 아직 안 만들어졌을 수 있어 같이 본다.
      final isUntouched = now == before && (existed || isUnknown);
      if ((isUnknown || after[rel] != now) && !isUntouched && !out.any((d) => d.path == rel)) {
        out.add((path: rel, isUnknown: isUnknown));
      }
      expected[rel] = before;
    }
  }
  return out;
}

/// 묶음 id 모양: `b_20261106-213000-a1b2`, `s_1a2b3c4d`, `undo`, `BRAIN_BATCH` 값.
/// 경로가 되므로 `/`·`..` 같은 글자는 받지 않는다 (11/11 K-18: `brain undo ../x`로 지식 폴더 밖을 고칠 수 있었다).
final batchIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,80}$');

String _undoDir(Vault vault, String batch) {
  if (!batchIdPattern.hasMatch(batch)) {
    throw ArgumentError('묶음 id 형식이 아닙니다: $batch (예: b_20261106-213000-a1b2, s_1a2b3c4d)');
  }
  return p.join(vault.metaDir, 'undo', batch);
}

/// 변경 기록(`_log/*.md`)에 나온 [prefix] 번호 중 가장 큰 값 (`n_`, `L-`, `T-`).
///
/// 색인은 지금 있는 파일만 알아서, 가장 큰 번호의 노트를 휴지통으로 보내면 다음 노트가 같은 번호를 받았다
/// (11/11 K-26: 변경 기록·세션 기록·대화 속 n_0050이 다른 노트를 가리키게 됨). 기록은 지우지 않으므로 번호를 다시 쓰지 않는다.
int maxLoggedNumber(Vault vault, String prefix) {
  final dir = Directory(vault.logDir);
  if (!dir.existsSync()) return 0;
  final pattern = RegExp('(?<![A-Za-z0-9_-])${RegExp.escape(prefix)}(\\d{1,6})(?![0-9])');
  var max = 0;
  for (final file in dir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.md')) continue;
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    for (final m in pattern.allMatches(text)) {
      final n = int.parse(m.group(1)!);
      if (n > max) max = n;
    }
  }
  return max;
}

/// 묶음 목록(`manifest.jsonl`)을 이 프로세스가 마지막으로 본 모양: 파일 크기, 이미 남긴 경로, 줄 수.
/// 파일마다 목록을 처음부터 다시 읽으면 한 묶음에 파일이 많을 때(폴더 정리 1만 개 = 2만 줄) 길이의 제곱으로 느려졌다
/// (설계서_프롬프트이후 5.1). 크기가 다르면(다른 프로세스가 같은 묶음에 씀, `BRAIN_BATCH`) 다시 읽는다.
final _manifestCache = <String, ({int size, Set<String> paths, int lines})>{};

/// 파일을 바꾸기 전 상태를 묶음에 남긴다. 같은 묶음에서 같은 파일은 처음 한 번만.
void recordBeforeChange(Vault vault, String path, {String? batch}) {
  final id = batch ?? currentBatch;
  final dir = _undoDir(vault, id);
  // 이미 남긴 파일이어도 이번에 또 바뀌므로 "바꾼 뒤" 해시는 다시 적는다 (위 [_recordAfterChanges]).
  _pendingAfter.putIfAbsent(id, () => {}).add(path);
  final rel = p.relative(path, from: vault.root);
  final manifest = File(p.join(dir, 'manifest.jsonl'));
  final size = manifest.existsSync() ? manifest.lengthSync() : -1;
  var cached = _manifestCache[manifest.path];
  if (cached == null || cached.size != size) {
    final lines = size < 0 ? const <String>[] : manifest.readAsLinesSync();
    final paths = <String>{};
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        paths.add((jsonDecode(line) as Map<String, dynamic>)['path'] as String);
      } on FormatException {
        continue;
      }
    }
    cached = (size: size, paths: paths, lines: lines.length);
  }
  if (cached.paths.contains(rel)) {
    _manifestCache[manifest.path] = cached;
    return;
  }
  Directory(p.join(dir, 'files')).createSync(recursive: true);
  final file = File(path);
  String? backup;
  if (file.existsSync()) {
    backup = 'files/${cached.lines}${p.extension(path)}';
    file.copySync(p.join(dir, backup));
  }
  // 'at': 이 묶음이 이 파일을 처음 바꾼 때(마이크로초). 옮긴 묶음을 되돌릴 때 "그 뒤에" 같은 자리를 고친 묶음을 가린다
  // (설계서_프롬프트이후 5.1, 11/13 검토). 예전 줄에는 없다.
  final line = '${jsonEncode({'path': rel, 'existed': backup != null, 'backup': backup, 'at': DateTime.now().microsecondsSinceEpoch})}\n';
  manifest.writeAsStringSync(line, mode: FileMode.append, flush: true);
  _manifestCache[manifest.path] = (
    size: (size < 0 ? 0 : size) + utf8.encode(line).length,
    paths: cached.paths..add(rel),
    lines: cached.lines + 1,
  );
}

/// 묶음 폴더 안 "경로 바뀜" 표시 파일: 이 묶음이 가리키는 파일을 옮긴 묶음 id들 (줄마다 하나).
const _pathsMovedFile = 'paths-moved';

/// 묶음 폴더 안 옮긴 기록: 줄마다 `{"from": 옛 경로, "to": 새 경로}` (지식 폴더 기준). 옮긴 묶음을 되돌리기 전에
/// 그 뒤 새 자리를 고친 묶음이 있는지 본다 ([undoBatch], 설계서_프롬프트이후 5.1, 11/13 검토).
const _movesFile = 'moves.jsonl';

/// 묶음 [batch]가 [from]을 [to]로 옮긴다고 적는다. 파일을 옮기기 **전에** 부른다 (끊겨도 기록이 남게).
void recordMove(Vault vault, String batch, String from, String to) {
  final dir = Directory(_undoDir(vault, batch))..createSync(recursive: true);
  File(p.join(dir.path, _movesFile)).writeAsStringSync(
    '${jsonEncode({'from': p.relative(from, from: vault.root), 'to': p.relative(to, from: vault.root)})}\n',
    mode: FileMode.append,
    flush: true,
  );
}

/// 옮기는 묶음 [mover]보다 앞선 되돌리기 묶음 중 옮길 파일을 가리키는 것에 "경로 바뀜"을 단다 (설계서_프롬프트이후 8.3).
/// 그 묶음을 되돌리면 옛 자리에 같은 번호의 노트가 하나 더 생기거나, 새로 만든 노트를 못 치운다.
/// 옮긴 묶음을 되돌리면 표시가 저절로 풀린다 ([UndoBatch.isPathMoved]).
///
/// 파일마다 **옮기기 전에** 단다 (11/13 검토): 예전에는 다 옮긴 뒤 한 번에 달아, `brain move --apply-plan`을 Ctrl-C로
/// 끊거나 앱이 덩어리 중간에 꺼지면 이미 옮긴 노트의 옛 묶음이 표시 없이 남았다 → 되돌리면 옛 자리에 노트가 다시 생겼다.
/// 먼저 달아도 안전하다: 옮긴 묶음의 목록(`manifest.jsonl`)이 생기기 전까지 표시는 힘이 없다 ([_isPathMoved]).
/// 되돌리기 목록은 처음에 한 번만 읽는다 (파일마다 읽으면 1만 개에서 느림).
class MovedPathMarker {
  MovedPathMarker(this.vault, this.mover) {
    final root = Directory(p.join(vault.metaDir, 'undo'));
    if (!root.existsSync()) return;
    for (final dir in root.listSync().whereType<Directory>()) {
      final name = p.basename(dir.path);
      if (name == mover || File(p.join(dir.path, 'undone')).existsSync()) continue;
      final manifest = File(p.join(dir.path, 'manifest.jsonl'));
      if (!manifest.existsSync()) continue;
      for (final line in manifest.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          final path = (jsonDecode(line) as Map<String, dynamic>)['path'];
          if (path is String) _dirsByPath.putIfAbsent(path, () => {}).add(dir.path);
        } on FormatException {
          continue;
        }
      }
    }
  }

  final Vault vault;
  final String mover;

  /// 지식 폴더 기준 경로 → 그 경로를 바꾼 묶음 폴더들.
  final _dirsByPath = <String, Set<String>>{};

  /// 이번에 이미 표시한 묶음 폴더.
  final _marked = <String>{};

  /// [fromPath](지식 폴더 기준)를 옮기기 직전에 부른다.
  void mark(String fromPath) {
    for (final dir in _dirsByPath[fromPath] ?? const <String>{}) {
      if (!_marked.add(dir)) continue;
      final file = File(p.join(dir, _pathsMovedFile));
      final movers = file.existsSync() ? file.readAsLinesSync() : const <String>[];
      if (!movers.contains(mover)) file.writeAsStringSync('$mover\n', mode: FileMode.append, flush: true);
    }
  }
}

/// [fromPaths]를 옮긴 묶음 [mover]보다 앞선 묶음에 "경로 바뀜"을 한꺼번에 단다 ([MovedPathMarker]).
void markMovedPaths(Vault vault, Set<String> fromPaths, String mover) {
  final marker = MovedPathMarker(vault, mover);
  fromPaths.forEach(marker.mark);
}

/// 옮긴 묶음 [dir]을 되돌리면 노트가 둘이 되는가: 그 뒤 다른 묶음이 옮긴 자리(옛·새 경로)를 바꿨으면 그 묶음 id들.
///
/// 예 (11/13 검토): 묶음 T가 A → B로 옮기고, 그 뒤 묶음 L이 B를 고쳤다. T를 되돌리면 B(L의 고침 포함)는 휴지통으로,
/// A는 고치기 전 내용으로 돌아온다. 이어서 L을 되돌리면 B가 다시 생겨 같은 번호의 노트가 A와 B에 둘이다.
/// 그래서 T는 L을 먼저 되돌린 뒤에만 되돌린다 — 아무 파일도 덮거나 잃지 않는 순서다.
///
/// "그 뒤"는 묶음 목록 줄의 시각(`at`)으로 본다. 시각이 없는 예전 줄은 바꾸기 전 사본이 T가 남긴 "바꾼 뒤"와 같으면 그 뒤로 본다.
List<String> _laterBatchesOnMovedPaths(Vault vault, String batch, String dir) {
  final movesFile = File(p.join(dir, _movesFile));
  if (!movesFile.existsSync()) return const [];
  final moved = <String>{};
  for (final line in movesFile.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      moved.addAll([json['from'] as String, json['to'] as String]);
    } on FormatException {
      continue;
    }
  }
  if (moved.isEmpty) return const [];
  final mine = <String, int?>{}; // 경로 → 이 묶음이 처음 바꾼 시각
  for (final line in File(p.join(dir, 'manifest.jsonl')).readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final entry = _jsonLine(line);
    if (entry == null) continue;
    final path = entry['path'] as String;
    if (moved.contains(path)) mine[path] = entry['at'] as int?;
  }
  final after = _afterHashes(dir);
  final out = <String>[];
  for (final other in Directory(p.join(vault.metaDir, 'undo')).listSync().whereType<Directory>()) {
    final name = p.basename(other.path);
    if (name == batch || File(p.join(other.path, 'undone')).existsSync()) continue;
    final manifest = File(p.join(other.path, 'manifest.jsonl'));
    if (!manifest.existsSync()) continue;
    for (final line in manifest.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final Map<String, dynamic> entry;
      try {
        entry = jsonDecode(line) as Map<String, dynamic>;
      } on FormatException {
        continue;
      }
      final path = entry['path'];
      if (path is! String || !moved.contains(path)) continue;
      final at = entry['at'] as int?;
      final myAt = mine[path];
      final backup = entry['backup'] as String?;
      final isLater = at != null && myAt != null
          ? at > myAt
          : backup != null && after[path] != null && fileHash(p.join(other.path, backup)) == after[path];
      if (isLater) {
        out.add(name);
        break;
      }
    }
  }
  return out..sort();
}

/// 깨진 줄(전원이 꺼져 반쯤 쓰인 줄)은 건너뛴다.
Map<String, dynamic>? _jsonLine(String line) {
  try {
    return jsonDecode(line) as Map<String, dynamic>;
  } on FormatException {
    return null;
  }
}

/// 묶음 폴더 [dir]의 "경로 바뀜" 표시 중 아직 살아 있는 것 (옮긴 묶음을 되돌렸으면 풀림).
bool _isPathMoved(Vault vault, String dir) {
  final mark = File(p.join(dir, _pathsMovedFile));
  if (!mark.existsSync()) return false;
  for (final mover in mark.readAsLinesSync()) {
    if (mover.trim().isEmpty || !batchIdPattern.hasMatch(mover.trim())) continue;
    final moverDir = p.join(vault.metaDir, 'undo', mover.trim());
    if (File(p.join(moverDir, 'manifest.jsonl')).existsSync() && !File(p.join(moverDir, 'undone')).existsSync()) {
      return true;
    }
  }
  return false;
}

class UndoBatch {
  const UndoBatch({
    required this.id,
    required this.files,
    required this.at,
    required this.isUndone,
    this.isPathMoved = false,
  });

  final String id;
  final int files;
  final DateTime at;
  final bool isUndone;

  /// 이 묶음이 바꾼 노트를 그 뒤 다른 자리로 옮겼다 ("경로 바뀜", 설계서_프롬프트이후 8.3). 되돌리지 않는다.
  final bool isPathMoved;
}

/// 되돌릴 수 있는 최근 묶음 (최신 순).
List<UndoBatch> recentBatches(Vault vault, {int limit = 10}) {
  final root = Directory(p.join(vault.metaDir, 'undo'));
  if (!root.existsSync()) return const [];
  final batches = <UndoBatch>[];
  for (final dir in root.listSync().whereType<Directory>()) {
    final manifest = File(p.join(dir.path, 'manifest.jsonl'));
    if (!manifest.existsSync()) continue;
    batches.add(
      UndoBatch(
        id: p.basename(dir.path),
        files: manifest.readAsLinesSync().where((l) => l.isNotEmpty).length,
        at: manifest.statSync().modified,
        isUndone: File(p.join(dir.path, 'undone')).existsSync(),
        isPathMoved: _isPathMoved(vault, dir.path),
      ),
    );
  }
  batches.sort((a, b) => b.at.compareTo(a.at));
  return batches.take(limit).toList();
}

/// 되돌리며 비워진 `wiki/` 아래 폴더(구역/주제)를 위로 올라가며 지운다. 자동 목차(첫 줄 "(자동 생성)")만 남았어도 빈 것으로 본다.
/// 폴더 정리(설계서_프롬프트이후 5.1)를 되돌리면 빈 구역/주제 폴더가 사이드바에 0개짜리 주제로 남았다.
void _removeEmptyWikiDirs(Vault vault, Set<String> dirs) {
  for (var dir in dirs) {
    while (p.isWithin(vault.wikiDir, dir)) {
      final folder = Directory(dir);
      if (!folder.existsSync()) {
        dir = p.dirname(dir);
        continue;
      }
      final entries = folder.listSync();
      final isEmpty = entries.every((e) {
        final name = p.basename(e.path);
        if (name == '.DS_Store') return true;
        if (name != 'index.md' || e is! File) return false;
        try {
          return e.readAsLinesSync().firstOrNull?.contains('(자동 생성)') ?? true;
        } on FileSystemException {
          return false;
        }
      });
      if (!isEmpty) break;
      try {
        folder.deleteSync(recursive: true);
      } on FileSystemException {
        break;
      }
      dir = p.dirname(dir);
    }
  }
}

/// 되돌리기를 거절했다: 묶음이 바꾼 파일이 그 뒤 다른 곳에서 바뀌었거나, "바꾼 뒤" 기록이 없어 확인할 수 없다.
/// [ArgumentError]라 예전처럼 잡는 곳(`brain undo`, 설정 [되돌리기])은 그대로 메시지를 보인다. [force]로 다시 부를 수 있다.
class UndoDriftError extends ArgumentError {
  UndoDriftError(this.batch, this.drift, String message) : super(message);

  final String batch;
  final List<BatchDrift> drift;
}

/// 묶음 하나를 통째로 되돌린다. 원래 있던 파일은 되살리고, 새로 생긴 파일은
/// 지우지 않고 `_meta/trash/<묶음>/`으로 옮긴다. 반환: 되돌린 파일 수.
///
/// 되돌리기 전에 묶음이 바꾼 파일이 모두 **그 묶음이 남긴 그대로**인지 본다 ([driftSinceBatches], 데이터 안전 감사 11/14).
/// 예전에는 경로만 보고 덮거나 치워, 버린 초안 자리에 새로 저장한 노트가 사본 없이 사라지고(되살린 초안이 덮음),
/// 제목을 바꾼 노트의 앞 고침을 되돌리면 같은 번호의 노트가 둘이 됐다. 하나라도 다르면 아무것도 바꾸지 않고
/// [UndoDriftError]를 던진다. "바꾼 뒤" 기록이 없는 11/13 전 묶음과 중간에 끊긴 묶음도 확인할 수 없어 거절한다.
/// [force]면 그래도 되돌리되, 덮거나 치울 지금 파일은 모두 휴지통(`_meta/trash/<묶음>/`)에 먼저 남긴다.
/// 지식 폴더 잠금 안에서 한다 (그사이 저장이 끼어들지 않게).
int undoBatch(Vault vault, String batch, {bool force = false}) => withVaultLock(vault, () => _undoBatch(vault, batch, force: force));

int _undoBatch(Vault vault, String batch, {required bool force}) {
  final dir = _undoDir(vault, batch);
  final manifest = File(p.join(dir, 'manifest.jsonl'));
  if (!manifest.existsSync()) {
    throw ArgumentError('$batch 묶음이 없습니다. brain undo 로 목록을 보세요.');
  }
  final undoneMark = File(p.join(dir, 'undone'));
  if (undoneMark.existsSync()) {
    throw ArgumentError('$batch 묶음은 이미 되돌렸습니다.');
  }
  if (_isPathMoved(vault, dir)) {
    throw ArgumentError(
      '$batch 묶음은 경로 바뀜: 그 뒤 폴더 정리로 노트를 옮겨 되돌리면 옛 자리에 같은 노트가 하나 더 생깁니다. '
      '되돌리려면 옮긴 묶음(${File(p.join(dir, _pathsMovedFile)).readAsLinesSync().where((l) => l.trim().isNotEmpty).join(', ')})을 먼저 되돌리세요.',
    );
  }
  final later = _laterBatchesOnMovedPaths(vault, batch, dir);
  if (later.isNotEmpty) {
    throw ArgumentError(
      '$batch 묶음은 노트를 옮긴 묶음인데, 그 뒤 다른 묶음(${later.join(', ')})이 옮긴 노트의 새 자리나 옛 자리를 바꿨습니다. '
      '지금 되돌리면 그 고침이 휴지통으로 가고, 그 묶음을 나중에 되돌리면 같은 노트가 둘이 됩니다. '
      '${later.join(', ')}을 먼저 되돌리세요 (설계서_프롬프트이후 5.1).',
    );
  }
  final entries = [
    for (final line in manifest.readAsLinesSync())
      if (line.trim().isNotEmpty) ?_jsonLine(line),
  ].reversed;
  final drift = driftSinceBatches(vault, [batch]);
  if (drift.isNotEmpty && !force) {
    final changed = [for (final d in drift) if (!d.isUnknown) d.path];
    final unknown = [for (final d in drift) if (d.isUnknown) d.path];
    throw UndoDriftError(
      batch,
      drift,
      '$batch 묶음을 되돌리지 않았습니다 — 되돌리면 지금 파일이 사라질 수 있습니다. '
      '${changed.isEmpty ? '' : '그 뒤 다른 작업이 바꾼 파일: ${changed.take(5).join(', ')}${changed.length > 5 ? ' 외 ${changed.length - 5}개' : ''}. '}'
      '${unknown.isEmpty ? '' : '바꾼 뒤 상태 기록이 없어 확인할 수 없는 파일(11/13 전 묶음이거나 중간에 끊긴 묶음): ${unknown.take(5).join(', ')}${unknown.length > 5 ? ' 외 ${unknown.length - 5}개' : ''}. '}'
      '더 최근 묶음을 먼저 되돌리거나, 그래도 되돌리려면 brain undo $batch --force (지금 파일은 _meta/trash/에 남깁니다).',
    );
  }
  final drifted = {for (final d in drift) d.path};
  var count = 0;
  final emptied = <String>{}; // 새로 생겼던 파일을 치운 폴더
  final stamp = DateTime.now().millisecondsSinceEpoch;
  // 같은 이름의 묶음을 전에 되돌린 적이 있으면 휴지통 폴더를 따로 쓴다 (앞 휴지통 파일을 덮지 않게)
  final trashName = Directory(p.join(vault.metaDir, 'trash', batch)).existsSync() ? '$batch-u$stamp' : batch;
  // 남이 준 백업을 복원한 뒤 되돌리기를 누르는 경우 등: manifest 경로가 지식 폴더 밖이면 아무것도 하지 않는다.
  for (final entry in entries) {
    final target = p.normalize(p.join(vault.root, entry['path'] as String));
    final backupRel = entry['backup'] as String?;
    if (!vault.contains(target) || target == vault.root ||
        (backupRel != null && !p.isWithin(dir, p.normalize(p.join(dir, backupRel))))) {
      throw ArgumentError('$batch 묶음의 경로가 지식 폴더 밖을 가리킵니다: ${entry['path']} — 되돌리지 않았습니다.');
    }
  }
  for (final entry in entries) {
    final target = p.join(vault.root, entry['path'] as String);
    if (entry['existed'] == true) {
      final backup = File(p.join(dir, entry['backup'] as String));
      // 강제로 되돌릴 때 그 뒤 바뀐 지금 파일은 덮기 전에 휴지통에 남긴다 (무엇을 해도 내용이 사라지지 않게)
      final current = File(target);
      if (drifted.contains(entry['path']) && current.existsSync()) {
        final keep = p.join(vault.metaDir, 'trash', trashName, entry['path'] as String);
        Directory(p.dirname(keep)).createSync(recursive: true);
        current.copySync(keep);
      }
      // 바이트로 되살린다: 첨부 사진(assets/)도 묶음에 들어온다 (설계서_프롬프트이후 5.5)
      writeBytesAtomic(target, backup.readAsBytesSync());
    } else {
      final file = File(target);
      if (!file.existsSync()) continue;
      // 이 묶음에서 새로 붙인 사진이라도 그사이 다른 노트가 같은 사진을 붙였으면 남긴다 (설계서_프롬프트이후 5.5).
      // 항목을 거꾸로 돌아 이 묶음의 노트는 이미 치운 뒤다.
      final rel = entry['path'] as String;
      if (rel.startsWith('$assetsDirName/') && isAssetReferenced(vault, p.basename(rel))) continue;
      final trash = p.join(vault.metaDir, 'trash', trashName, entry['path'] as String);
      Directory(p.dirname(trash)).createSync(recursive: true);
      file.renameSync(trash);
      emptied.add(p.dirname(target));
    }
    count++;
  }
  _removeEmptyWikiDirs(vault, emptied);
  undoneMark.writeAsStringSync(formatTime(DateTime.now()));
  // 되돌린 묶음은 이름을 바꿔 보관한다. 세션 묶음(s_<세션 앞 8자>)은 같은 세션에서 다시 저장하면 같은 이름을 쓰는데,
  // 예전에는 "이미 되돌림" 표시가 남은 폴더에 새 저장이 쌓여 다시 되돌릴 수 없었다 (11/11 K-35).
  Directory(dir).renameSync('$dir-u$stamp');
  // 세션 묶음을 되돌리면 그 세션은 다시 "저장 안 함"이다 — 자동 정리·지난 대화 목록에 다시 나온다.
  if (batch.startsWith('s_') && batch.length > 2) {
    final prefix = batch.substring(2);
    final registry = SessionRegistry(vault);
    for (final MapEntry(key: id, value: status) in registry.load().entries) {
      if (id.startsWith(prefix) && (status == SessionStatus.saved || status == SessionStatus.partial)) {
        registry.mark(id, SessionStatus.unsaved);
      }
    }
  }
  appendChangeLog(vault, 'undo', '$batch 파일 $count개', batch: 'undo');
  return count;
}
