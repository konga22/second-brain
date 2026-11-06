import 'package:brain_core/brain_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/vault_path.dart';

/// 앱 안에서 SQLite 기능과 지식 폴더 접근을 점검한다 (1주차 완료 기준).
final systemCheckProvider = FutureProvider<(SqliteSupport, VaultAccess)>((
  ref,
) async {
  final sqlite = checkSqliteSupport();
  final vault = await checkVaultAccess(defaultVaultPath());
  debugPrint(
    '[점검] SQLite ${sqlite.version} ${sqlite.items} / '
    '지식 폴더 ${vault.path} ${vault.items} ${vault.error ?? ''}',
  );
  return (sqlite, vault);
});
