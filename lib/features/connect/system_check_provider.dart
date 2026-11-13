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
    this.gitExposure,
  });

  final SqliteSupport sqlite;
  final VaultAccess vault;

  /// null이면 Supabase 설정 전이다. 설정 전은 문제로 치지 않는다.
  final bool? isSupabaseReachable;

  /// 지식 폴더가 원격이 붙은 git 폴더 안이면 그 저장소 (설계서_프롬프트이후 4.6). 경고라 연동 메뉴에 점만 띄운다.
  final GitRemoteExposure? gitExposure;

  bool get hasProblem =>
      !sqlite.isReady ||
      !vault.isReady ||
      isSupabaseReachable == false ||
      gitExposure != null;
}

final systemCheckProvider = FutureProvider<SystemCheck>((ref) async {
  final vaultPath = defaultVaultPath();
  final check = SystemCheck(
    sqlite: checkSqliteSupport(),
    vault: await checkVaultAccess(vaultPath),
    isSupabaseReachable: await checkSupabaseReachable(),
    gitExposure: findGitRemoteExposure(vaultPath),
  );
  debugPrint(
    '[점검] SQLite ${check.sqlite.version} ${check.sqlite.items} / '
    '지식 폴더 ${check.vault.path} ${check.vault.items} ${check.vault.error ?? ''} / '
    'Supabase ${check.isSupabaseReachable ?? '설정 전'} / '
    'git 원격 ${check.gitExposure?.warning ?? '없음'}',
  );
  return check;
});
