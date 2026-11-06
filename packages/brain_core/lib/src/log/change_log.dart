import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../note/note.dart';
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
  file.writeAsStringSync(
    '- ${formatTime(now)} [${batch ?? currentBatch}] $action $detail\n',
    mode: FileMode.append,
    flush: true,
  );
}

String _undoDir(Vault vault, String batch) =>
    p.join(vault.metaDir, 'undo', batch);

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
  for (final entry in entries) {
    final target = p.join(vault.root, entry['path'] as String);
    if (entry['existed'] == true) {
      final backup = File(p.join(dir, entry['backup'] as String));
      writeFileAtomic(target, backup.readAsStringSync());
    } else {
      final file = File(target);
      if (!file.existsSync()) continue;
      final trash = p.join(vault.metaDir, 'trash', batch, entry['path'] as String);
      Directory(p.dirname(trash)).createSync(recursive: true);
      file.renameSync(trash);
    }
    count++;
  }
  undoneMark.writeAsStringSync(formatTime(DateTime.now()));
  appendChangeLog(vault, 'undo', '$batch 파일 $count개', batch: 'undo');
  return count;
}
