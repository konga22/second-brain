import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'brain_providers.dart';

/// 앱을 켤 때 지식 폴더 상태 (11/11 독립 검토 K-33 나머지).
///
/// 예전에는 앱이 켜지자마자 지식 폴더를 만들었다(`Vault.ensure`). 외장 디스크·USB에 둔 폴더가 빠져 있으면
/// - 상위 폴더가 있으면 빈 지식 폴더를 새로 만들고, 시작 동기화가 그 빈 폴더를 보고 색인(그래프 배치 포함)을 비웠다.
/// - 상위 폴더가 없으면(`/Volumes/<디스크>`) 만들다 실패해 앱 전체가 예외 화면이 됐다.
class VaultStart {
  const VaultStart.ready(this.root) : isReady = true, error = null;
  const VaultStart.missing(this.root, {this.error}) : isReady = false;

  final String root;
  final bool isReady;

  /// 처음 쓰는 폴더를 만들다 실패한 까닭.
  final String? error;
}

/// [vault]가 있으면 기본 구조를 맞추고 쓴다. 없으면:
/// - 이 폴더를 쓴 적이 있으면(색인 파일이 있다) 빠지거나 옮겨진 것일 수 있으니 새로 만들지 않고 묻는다.
/// - 처음 쓰는 폴더면 만든다 (첫 실행). 만들 수 없으면 묻는다.
VaultStart checkVaultAtStart(Vault vault) {
  if (Directory(vault.root).existsSync()) {
    vault.ensure();
    return VaultStart.ready(vault.root);
  }
  if (File(vault.indexPath).existsSync()) return VaultStart.missing(vault.root);
  try {
    vault.ensure();
    return VaultStart.ready(vault.root);
  } on FileSystemException catch (e) {
    return VaultStart.missing(
      vault.root,
      error: e.osError?.message ?? e.message,
    );
  }
}

/// 앱 전체가 이것이 준비된 뒤에만 그려진다 ([VaultGate]). [다시 확인]은 이것을 무효화한다.
final vaultStartProvider = Provider<VaultStart>(
  (ref) => checkVaultAtStart(ref.watch(vaultProvider)),
);
