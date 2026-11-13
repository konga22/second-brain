import 'dart:async';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../core/app_config_provider.dart';
import '../core/brain_providers.dart';
import '../core/vault_startup.dart';
import 'safe_set_state.dart';

/// 지식 폴더가 준비된 뒤에만 앱 화면을 그린다. 없으면 "지식 폴더를 찾지 못했습니다" 화면 (11/11 K-33 나머지).
///
/// 앱을 쓰는 중에 폴더가 사라져도(USB를 뽑음) 같은 화면으로 바꾼다. 전에는 켤 때만 봐서, 빠진 뒤에도
/// 지난 색인으로 노트가 보이고 저장은 실패했다 (작업인계 0-4 "앱이 켜진 채 폴더가 빠질 때").
class VaultGate extends ConsumerStatefulWidget {
  const VaultGate({super.key, required this.child});

  final Widget child;

  /// 폴더가 있는지 보는 간격. 폴더 감시는 디스크를 뽑을 때 알림 없이 끊길 수 있어 직접 본다.
  static const checkEvery = Duration(seconds: 2);

  @override
  ConsumerState<VaultGate> createState() => _VaultGateState();
}

class _VaultGateState extends ConsumerState<VaultGate> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(VaultGate.checkEvery, (_) => _check());
  }

  void _check() {
    final start = ref.read(vaultStartProvider);
    if (!start.isReady || Directory(start.root).existsSync()) return;
    // 지식 폴더·색인·감시를 모두 다시 만든다. 다시 볼 때 폴더가 없으면 묻는 화면이 된다.
    ref.invalidate(vaultProvider);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = ref.watch(vaultStartProvider);
    if (start.isReady) return widget.child;
    return _VaultMissingPage(start: start);
  }
}

class _VaultMissingPage extends ConsumerStatefulWidget {
  const _VaultMissingPage({required this.start});

  final VaultStart start;

  @override
  ConsumerState<_VaultMissingPage> createState() => _VaultMissingPageState();
}

class _VaultMissingPageState extends ConsumerState<_VaultMissingPage>
    with SafeSetState {
  String? _message;
  bool _isWorking = false;

  /// 외장 디스크를 다시 꽂은 뒤: 폴더가 있으면 그대로 앱이 열린다.
  void _onRetry() {
    // 폴더 확인만이 아니라 색인·폴더 감시까지 새로 만든다. 폴더가 없는 동안 만든 감시는 이미 끊겨 있어,
    // 다시 연결한 뒤 밖에서 넣은 노트가 화면에 안 나왔다 (11/12 통합 시험).
    ref.invalidate(vaultProvider);
    if (!ref.read(vaultStartProvider).isReady) {
      setState(
        () => _message = '아직 찾지 못했습니다. 디스크가 연결됐는지, 폴더 이름이 바뀌지 않았는지 확인하세요.',
      );
    }
  }

  /// 설정의 [폴더 바꾸기]와 같은 순서: 쓰기·읽기를 시험한 뒤에만 저장한다.
  Future<void> _onPickOther() async {
    final dir = await getDirectoryPath(confirmButtonText: '이 폴더 쓰기');
    if (dir == null) return;
    setState(() {
      _isWorking = true;
      _message = '폴더 점검 중…';
    });
    final access = await checkVaultAccess(dir);
    if (!mounted) return;
    if (!access.canWrite || !access.canRead) {
      setState(() {
        _isWorking = false;
        _message =
            '이 폴더는 쓸 수 없습니다: $dir${access.error == null ? '' : ' (${access.error})'}';
      });
      return;
    }
    ref
        .read(appConfigProvider.notifier)
        .update((c) => c.copyWith(vaultPath: dir));
    ref.invalidate(vaultProvider);
    setState(() => _isWorking = false);
  }

  /// [여기에 빈 폴더 새로 만들기]를 한 번 눌렀다 → 한 번 더 확인한다.
  /// (이 화면은 앱 화면(라우터) 바깥이라 대화상자를 띄울 Navigator가 없다.)
  bool _isConfirmingCreate = false;

  /// 원래 자리에 빈 지식 폴더를 새로 만든다. 노트는 없는 채로 시작한다.
  void _onCreateHere() {
    if (!_isConfirmingCreate) {
      setState(() {
        _isConfirmingCreate = true;
        _message = '노트가 없는 새 폴더를 만듭니다. 외장 디스크에 있던 폴더라면 먼저 연결하고 [다시 확인]을 누르세요. 그래도 만들려면 한 번 더 누르세요.';
      });
      return;
    }
    try {
      Vault(widget.start.root).ensure();
    } on FileSystemException catch (e) {
      setState(
        () => _message = '만들지 못했습니다: ${e.osError?.message ?? e.message}',
      );
      return;
    }
    ref.invalidate(vaultProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ColoredBox(
      color: theme.colorScheme.background,
      child: DefaultTextStyle(
        style: theme.textTheme.p,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    LucideIcons.folderX,
                    size: 32,
                    color: theme.colorScheme.mutedForeground,
                  ),
                  const SizedBox(height: 16),
                  Text('지식 폴더를 찾지 못했습니다', style: theme.textTheme.h3),
                  const SizedBox(height: 8),
                  Text(widget.start.root, style: theme.textTheme.small),
                  const SizedBox(height: 12),
                  Text(
                    widget.start.error == null
                        ? '외장 디스크·USB에 있는 폴더라면 연결한 뒤 [다시 확인]을 누르세요. '
                              '앱은 아무것도 지우거나 새로 만들지 않았습니다.'
                        : '폴더를 만들 수 없습니다 (${widget.start.error}). 다른 폴더를 고르세요.',
                    style: theme.textTheme.muted,
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ShadButton(
                        enabled: !_isWorking,
                        onPressed: _onRetry,
                        child: const Text('다시 확인'),
                      ),
                      ShadButton.outline(
                        enabled: !_isWorking,
                        leading: const Icon(LucideIcons.folderOpen, size: 14),
                        onPressed: _onPickOther,
                        child: const Text('다른 폴더 고르기'),
                      ),
                      if (widget.start.error == null)
                        ShadButton.ghost(
                          enabled: !_isWorking,
                          onPressed: _onCreateHere,
                          child: Text(
                            _isConfirmingCreate
                                ? '빈 폴더 만들기 (확인)'
                                : '여기에 빈 폴더 새로 만들기',
                          ),
                        ),
                    ],
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(_message!, style: theme.textTheme.small),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
