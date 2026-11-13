import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../note/note.dart';
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
  file.writeAsStringSync(
    '- ${formatTime(now)} [${batch ?? currentBatch}] $action $detail$mark\n',
    mode: FileMode.append,
    flush: true,
  );
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

/// 파일을 바꾸기 전 상태를 묶음에 남긴다. 같은 묶음에서 같은 파일은 처음 한 번만.
void recordBeforeChange(Vault vault, String path, {String? batch}) {
  final id = batch ?? currentBatch;
  final dir = _undoDir(vault, id);
  final rel = p.relative(path, from: vault.root);
  final manifest = File(p.join(dir, 'manifest.jsonl'));
  if (manifest.existsSync() &&
      manifest.readAsLinesSync().any((l) => l.contains(jsonEncode(rel)))) {
    return;
  }
  Directory(p.join(dir, 'files')).createSync(recursive: true);
  final file = File(path);
  String? backup;
  if (file.existsSync()) {
    final n = manifest.existsSync() ? manifest.readAsLinesSync().length : 0;
    backup = 'files/$n${p.extension(path)}';
    file.copySync(p.join(dir, backup));
  }
  manifest.writeAsStringSync(
    '${jsonEncode({'path': rel, 'existed': backup != null, 'backup': backup})}\n',
    mode: FileMode.append,
    flush: true,
  );
}

class UndoBatch {
  const UndoBatch({
    required this.id,
    required this.files,
    required this.at,
    required this.isUndone,
  });

  final String id;
  final int files;
  final DateTime at;
  final bool isUndone;
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
      ),
    );
  }
  batches.sort((a, b) => b.at.compareTo(a.at));
  return batches.take(limit).toList();
}

/// 묶음 하나를 통째로 되돌린다. 원래 있던 파일은 되살리고, 새로 생긴 파일은
/// 지우지 않고 `_meta/trash/<묶음>/`으로 옮긴다. 반환: 되돌린 파일 수.
int undoBatch(Vault vault, String batch) {
  final dir = _undoDir(vault, batch);
  final manifest = File(p.join(dir, 'manifest.jsonl'));
  if (!manifest.existsSync()) {
    throw ArgumentError('$batch 묶음이 없습니다. brain undo 로 목록을 보세요.');
  }
  final undoneMark = File(p.join(dir, 'undone'));
  if (undoneMark.existsSync()) {
    throw ArgumentError('$batch 묶음은 이미 되돌렸습니다.');
  }
  final entries = [
    for (final line in manifest.readAsLinesSync())
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
  ].reversed;
  var count = 0;
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
      writeFileAtomic(target, backup.readAsStringSync());
    } else {
      final file = File(target);
      if (!file.existsSync()) continue;
      final trash = p.join(vault.metaDir, 'trash', trashName, entry['path'] as String);
      Directory(p.dirname(trash)).createSync(recursive: true);
      file.renameSync(trash);
    }
    count++;
  }
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
