import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/app_config_provider.dart';
import '../../core/brain_providers.dart';
import 'persona_form.dart';

/// 지식 폴더의 `me.md`를 읽어 4문항 칸에 채우고, [저장]하면 다시 쓴다 (설계서_프롬프트이후 5.2).
/// 파일이 작아(몇백 바이트) 화면 스레드에서 읽고 쓴다.
class PersonaCard extends ConsumerStatefulWidget {
  const PersonaCard({super.key, required this.title, this.onSkip, this.onSaved});

  final String title;

  /// 있으면 [건너뛰기]를 보인다.
  final VoidCallback? onSkip;
  final VoidCallback? onSaved;

  @override
  ConsumerState<PersonaCard> createState() => _PersonaCardState();
}

class _PersonaCardState extends ConsumerState<PersonaCard> {
  late Persona _initial;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    try {
      _initial = Persona.load(ref.read(vaultProvider)) ?? const Persona();
    } on Object catch (e) {
      // 못 읽은 채 저장하면 손으로 쓴 내용을 빈 값으로 덮어쓴다 — 고치기 전에 알린다.
      _initial = const Persona();
      _loadError = 'me.md를 읽지 못했습니다: $e — Finder에서 파일을 확인하세요. 읽을 수 있을 때까지 저장하지 않습니다.';
    }
  }

  Future<void> _onSave(Persona persona) async {
    if (_loadError != null) throw StateError('me.md를 읽지 못해 덮어쓰지 않습니다');
    persona.save(ref.read(vaultProvider));
    widget.onSaved?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return ShadCard(
      title: Text(widget.title),
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_loadError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_loadError!, style: TextStyle(color: colors.danger, fontSize: 13)),
              ),
            PersonaForm(initial: _initial, onSave: _onSave, onSkip: widget.onSkip),
          ],
        ),
      ),
    );
  }
}

/// [연동] 다음 단계 (설계서_프롬프트이후 5.2): 플러그인을 설치했고 `me.md`가 아직 없고 건너뛰지 않았을 때만 보인다.
/// 저장하거나 건너뛰면 사라지고, 그 뒤로는 [설정] > 나에 대해에서 고친다.
class PersonaStep extends ConsumerStatefulWidget {
  const PersonaStep({super.key, required this.isConnected});

  final bool isConnected;

  @override
  ConsumerState<PersonaStep> createState() => _PersonaStepState();
}

class _PersonaStepState extends ConsumerState<PersonaStep> {
  bool _isDone = false;

  void _onSkip() => ref.read(appConfigProvider.notifier).update((c) => c.copyWith(isPersonaSkipped: true));

  @override
  Widget build(BuildContext context) {
    final isSkipped = ref.watch(appConfigProvider.select((c) => c.isPersonaSkipped));
    final hasMe = File(ref.watch(vaultProvider).mePath).existsSync();
    if (!widget.isConnected || isSkipped || hasMe || _isDone) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: PersonaCard(
        title: '다음 단계: 나에 대해 4문항 (선택)',
        onSkip: _onSkip,
        onSaved: () {
          ShadToaster.maybeOf(context)?.show(
            const ShadToast(description: Text('나에 대해를 저장했습니다. [설정]에서 언제든 고칠 수 있습니다.')),
          );
          setState(() => _isDone = true);
        },
      ),
    );
  }
}
