import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../vault/vault.dart';

/// 놓친 교정 줍기에서 이미 훑은 곳 (설계서_프롬프트이후 5.10 ①). `_meta/correction_scan.json`에
/// 세션 id → 훑은 사용자 문장 수를 적는다. 세션이 이어지면 늘어난 문장만 다시 보여 준다.
/// 기기에만 둔다(사용자 문장은 넣지 않고 숫자만).
class CorrectionScanState {
  CorrectionScanState(this.vault);

  final Vault vault;

  File get _file => File(p.join(vault.metaDir, 'correction_scan.json'));

  Map<String, int> load() {
    if (!_file.existsSync()) return {};
    try {
      final json = jsonDecode(_file.readAsStringSync());
      if (json is! Map) return {};
      return {for (final e in json.entries) '${e.key}': (e.value as num).toInt()};
    } on FormatException {
      return {};
    }
  }

  /// [scanned]의 세션마다 훑은 수를 적는다. 줄어드는 값은 무시한다(늦게 끝난 실행이 앞선 기록을 되돌리지 않게).
  void markScanned(Map<String, int> scanned) => withVaultLock(vault, () {
    final now = load();
    for (final e in scanned.entries) {
      if (e.value > (now[e.key] ?? 0)) now[e.key] = e.value;
    }
    Directory(vault.metaDir).createSync(recursive: true);
    writeFileAtomic(_file.path, const JsonEncoder.withIndent(' ').convert(now));
  });
}
