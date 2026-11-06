import 'package:brain_core/brain_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_config.dart';
import '../../core/vault_path.dart';

/// 앱 실행 환경 점검 결과 (1주차 완료 기준).
class SystemCheck {
  const SystemCheck({
    required this.sqlite,
    required this.vault,
    required this.isSupabaseReachable,
  });

  final SqliteSupport sqlite;
  final VaultAccess vault;

  /// null이면 Supabase 설정 전이다. 설정 전은 문제로 치지 않는다.
  final bool? isSupabaseReachable;

  bool get hasProblem =>
      !sqlite.isReady || !vault.isReady || isSupabaseReachable == false;
}

final systemCheckProvider = FutureProvider<SystemCheck>((ref) async {
  final check = SystemCheck(
    sqlite: checkSqliteSupport(),
    vault: await checkVaultAccess(defaultVaultPath()),
    isSupabaseReachable: await checkSupabaseReachable(),
  );
  debugPrint(
    '[점검] SQLite ${check.sqlite.version} ${check.sqlite.items} / '
    '지식 폴더 ${check.vault.path} ${check.vault.items} ${check.vault.error ?? ''} / '
    'Supabase ${check.isSupabaseReachable ?? '설정 전'}',
  );
  return check;
});
