import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../vault/vault.dart';

/// 세션 축약본에서 AI가 실제로 읽은 범위 (`_meta/session_reads.json`).
///
/// 11/12 실측(O-7): 14만 자 세션을 `brain-save`로 정리하게 하자 스킬에 "끝까지 읽는다"고 적혀 있는데도
/// 쪽 크기 6,000·12,000·24,000자 세 번 모두 중간을 건너뛰고 저장했다(읽은 곳 60%·86%·43%).
/// 문장만으로는 지켜지지 않아 `brain`이 읽은 범위를 세고, 끝 표시와 저장 때 안 읽은 곳을 알려 준다.
class SessionReads {
  SessionReads(this.vault);

  final Vault vault;

  File get _file => File(p.join(vault.metaDir, 'session_reads.json'));

  Map<String, dynamic> _load() {
    if (!_file.existsSync()) return {};
    try {
      return jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
    } on FormatException {
      return {};
    }
  }

  List<(int, int)> _ranges(Map<String, dynamic> all, String sessionId) => [
    for (final r in (all[sessionId] as List<dynamic>? ?? const []))
      ((r as List<dynamic>)[0] as int, r[1] as int),
  ];

  /// [from, end)를 읽었다고 적고, [total]자 가운데 아직 안 읽은 범위를 돌려준다.
  /// 잠금 안에서 읽고 쓴다: 두 곳에서 동시에 적으면 서로의 기록을 덮었다 (데이터 안전 감사 11/14).
  List<(int, int)> record(String sessionId, int from, int end, int total) => withVaultLock(vault, () {
    Directory(vault.metaDir).createSync(recursive: true);
    final all = _load();
    final merged = _merge([..._ranges(all, sessionId), if (end > from) (from, end)]);
    all[sessionId] = [
      for (final (a, b) in merged) [a, b],
    ];
    Directory(vault.metaDir).createSync(recursive: true);
    writeFileAtomic(_file.path, jsonEncode(all));
    return _gaps(merged, total);
  });

  /// [total]자 가운데 아직 안 읽은 범위. 한 번도 안 읽었으면 전체.
  List<(int, int)> unread(String sessionId, int total) => _gaps(_merge(_ranges(_load(), sessionId)), total);

  static List<(int, int)> _merge(List<(int, int)> ranges) {
    final sorted = [...ranges]..sort((x, y) => x.$1.compareTo(y.$1));
    final result = <(int, int)>[];
    for (final (a, b) in sorted) {
      if (result.isNotEmpty && a <= result.last.$2) {
        final last = result.removeLast();
        result.add((last.$1, b > last.$2 ? b : last.$2));
      } else {
        result.add((a, b));
      }
    }
    return result;
  }

  static List<(int, int)> _gaps(List<(int, int)> merged, int total) {
    final gaps = <(int, int)>[];
    var at = 0;
    for (final (a, b) in merged) {
      if (a > at) gaps.add((at, a < total ? a : total));
      if (b > at) at = b;
      if (at >= total) break;
    }
    if (at < total) gaps.add((at, total));
    return [
      for (final g in gaps)
        if (g.$2 > g.$1) g,
    ];
  }

  /// 사람이 읽을 모양: "48000~60000, 108000~128000".
  static String describe(List<(int, int)> gaps) => gaps.map((g) => '${g.$1}~${g.$2}').join(', ');
}
