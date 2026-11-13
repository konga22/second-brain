import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/change_log.dart';
import '../note/file_name.dart';
import '../note/note.dart';
import '../security/secret_mask.dart';
import '../vault/vault.dart';

/// 가져오는 원본 종류 (설계서 5.6).
enum ImportKind {
  meeting('meetings', '회의록'),
  document('imports', '문서');

  const ImportKind(this.folder, this.label);

  final String folder;
  final String label;
}

class ImportResult {
  const ImportResult(this.relPath, this.maskedCount);

  final String relPath;

  /// 가린 비밀값 개수.
  final int maskedCount;
}

/// 텍스트 원본(.md·.txt)을 `raw/<종류>/`에 저장한다. 원본은 이후 고치지 않는다.
///
/// - 비밀값은 저장 전에 `[가림]`으로 바꾼다 (경로 B로 Claude API에 나가지 않게).
/// - 정리는 사용자 AI의 `brain-ingest` 스킬이 정리 대기 노트로 만든다.
/// - PDF·Word는 기기에 markitdown(MIT)이 있으면 그것으로 md로 바꿔서 넣는다 ([convertWithMarkitdown]).
ImportResult importText(
  Vault vault, {
  required String name,
  required String text,
  ImportKind kind = ImportKind.document,
  String? originalPath,
  String? batch,
}) {
  vault.ensure();
  final masked = maskSecrets(text);
  final maskedCount = '[가림]'.allMatches(masked).length -
      '[가림]'.allMatches(text).length;
  final now = DateTime.now();
  final date = formatTime(now).substring(0, 10);
  final title = p.basenameWithoutExtension(name).trim();
  final dir = p.join(vault.root, 'raw', kind.folder);
  final path = uniqueNotePath(dir, '$date-$title');
  final content = [
    '---',
    'title: ${jsonEncode(title)}',
    'source: import',
    'kind: ${kind.name}',
    'imported: ${formatTime(now)}',
    if (originalPath != null) 'original: ${jsonEncode(originalPath)}',
    '---',
    masked.trimRight(),
    '',
  ].join('\n');
  recordBeforeChange(vault, path, batch: batch);
  writeFileAtomic(path, content);
  final rel = p.relative(path, from: vault.root);
  appendChangeLog(vault, 'import', '${kind.label} $rel', batch: batch);
  return ImportResult(rel, maskedCount < 0 ? 0 : maskedCount);
}

/// 기기에 있는 markitdown으로 PDF·Word를 md로 바꾼다. 없으면 null.
Future<String?> convertWithMarkitdown(String path) async {
  for (final candidate in ['markitdown', '/opt/homebrew/bin/markitdown', '/usr/local/bin/markitdown']) {
    try {
      final result = await Process.run(candidate, [path], stdoutEncoding: utf8);
      if (result.exitCode == 0 && '${result.stdout}'.trim().isNotEmpty) {
        return '${result.stdout}';
      }
    } on ProcessException {
      continue;
    }
  }
  return null;
}
