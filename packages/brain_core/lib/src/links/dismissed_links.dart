import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../note/note.dart';
import '../vault/vault.dart';

/// 사용자가 거절한 추천 연결 `_meta/dismissed.jsonl` (설계서 4.1·5.5).
/// 색인은 다시 만들 수 있지만 거절은 사용자 결정이라 지식 폴더에 둔다.
class DismissedLinks {
  DismissedLinks(this.vault);

  final Vault vault;

  File get _file => File(p.join(vault.metaDir, 'dismissed.jsonl'));

  Set<(String, String)> load() {
    if (!_file.existsSync()) return const {};
    final pairs = <(String, String)>{};
    for (final line in _file.readAsLinesSync()) {
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        pairs.add(('${json['from']}', '${json['to']}'));
      } on FormatException {
        continue;
      }
    }
    return pairs;
  }

  void add(String from, String to) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      '${jsonEncode({'from': from, 'to': to, 'at': formatTime(DateTime.now())})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }
}
