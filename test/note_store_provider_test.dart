import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:secondbrain/core/app_config_provider.dart';
import 'package:secondbrain/core/brain_providers.dart';

/// 설정 [이전 방식]의 5.1 폴더 구조 스위치가 바로 반영된다 (설계서_프롬프트이후 5.1, 11/13 검토).
/// 예전에는 [noteStoreProvider]가 처음 만들 때 한 번만 설정을 읽어, 스위치를 바꿔도 앱을 다시 켜기 전까지
/// 새 노트·주제 만들기가 옛 방식 그대로였다.
class _MemoryConfig extends AppConfigNotifier {
  @override
  AppConfig build() => const AppConfig();
}

void main() {
  test('이전 방식 스위치를 바꾸면 노트 저장소가 새 방식으로 다시 만들어진다', () {
    final temp = Directory.systemTemp.createTempSync('store_provider_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final vault = Vault(p.join(temp.path, 'vault'))..ensure();
    final index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    addTearDown(index.close);
    final container = ProviderContainer(
      overrides: [
        vaultProvider.overrideWithValue(vault),
        searchIndexProvider.overrideWithValue(index),
        appConfigProvider.overrideWith(_MemoryConfig.new),
      ],
    );
    addTearDown(container.dispose);
    final isLegacyFromEnv = AppConfig.legacyItems(Platform.environment['BRAIN_LEGACY'], const {}).contains(AppConfig.legacyFolders);
    if (isLegacyFromEnv) markTestSkipped('BRAIN_LEGACY=folders 환경에서는 설정 스위치를 견줄 수 없다');
    expect(container.read(noteStoreProvider).isZoned, isTrue);
    container
        .read(appConfigProvider.notifier)
        .update((c) => c.copyWith(legacy: {AppConfig.legacyFolders}), save: false);
    expect(container.read(noteStoreProvider).isZoned, isFalse);
    container.read(appConfigProvider.notifier).update((c) => c.copyWith(legacy: const {}), save: false);
    expect(container.read(noteStoreProvider).isZoned, isTrue);
  });
}
