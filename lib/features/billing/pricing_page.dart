import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme/app_colors.dart';
import '../../core/ai_gateway.dart';
import '../../core/supabase_config.dart';
import '../auth/login_dialog.dart';
import '../../shared/safe_set_state.dart';

/// 요금제 (설계서 3절 `/pricing`, 6): 무료·Pro 비교, 모의 결제. 수치는 가안(미결정 5).
class PricingPage extends ConsumerStatefulWidget {
  const PricingPage({super.key});

  @override
  ConsumerState<PricingPage> createState() => _PricingPageState();
}

class _PricingPageState extends ConsumerState<PricingPage> with SafeSetState<PricingPage> {
  String? _message;
  bool _isWorking = false;

  Future<void> _onUpgrade() async {
    setState(() => _isWorking = true);
    try {
      await ref.read(aiGatewayProvider).mockCheckout();
      if (!mounted) return;
      ref.invalidate(planProvider);
      setState(() => _message = 'Pro로 바꿨습니다 (모의 결제, 30일).');
    } on AiGatewayException catch (e) {
      setState(() => _message = e.message);
    } finally {
      setState(() => _isWorking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final user = ref.watch(authUserProvider).value;
    final plan = ref.watch(planProvider).value;
    Widget column(
      String name,
      String price,
      List<String> items, {
      Widget? action,
      bool highlight = false,
    }) => Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: highlight ? colors.accent : colors.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: theme.textTheme.large),
            Text(price, style: theme.textTheme.h3),
            const SizedBox(height: 10),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $item'),
              ),
            if (action != null) ...[const SizedBox(height: 12), action],
          ],
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
      children: [
        Row(
          children: [
            Text('요금제', style: theme.textTheme.h4),
            const Spacer(),
            if (user != null) ...[
              Text(user.email ?? '', style: theme.textTheme.muted),
              const SizedBox(width: 8),
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: () => Supabase.instance.client.auth.signOut(),
                child: const Text('로그아웃'),
              ),
            ] else if (SupabaseConfig.isConfigured)
              ShadButton(
                size: ShadButtonSize.sm,
                onPressed: () => showLoginDialog(context),
                child: const Text('로그인'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          plan == null
              ? '로그인하면 지금 요금제와 이번 달 사용량이 보입니다.'
              : '지금: ${plan.isPro ? 'Pro' : '무료'} · 이번 달 남은 AI 크레딧 ${plan.remainingCredits.toStringAsFixed(1)} / ${plan.limitCredits.toStringAsFixed(0)} (질문 약 ${plan.remainingQuestions}회)${plan.isPro && plan.renewsAt != null ? ' · ${plan.renewsAt!.toLocal().toString().substring(0, 10)}까지' : ''}',
          style: theme.textTheme.muted,
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            column('무료', '0원', [
              '노트 200개·실수 노트 20개 (가안, 기기 안 저장이라 넘어도 막지 않고 안내만)',
              'Claude Code 연동 (경로 A, 서버를 안 거쳐 횟수 무제한)',
              'AI 크레딧 월 60 (앱 안 AI 질문 약 23회)',
            ]),
            column(
              'Pro',
              '월 12,900원 (가안)',
              [
                '무료의 모든 기능',
                'AI 크레딧 월 3,000 (질문 약 1,160회)',
                '답을 고치면 실수 노트로 검증',
                '가져온 대화 자동 묶음 이름',
              ],
              highlight: true,
              action: ShadButton(
                enabled: user != null && !(plan?.isPro ?? false) && !_isWorking,
                onPressed: _onUpgrade,
                child: Text(plan?.isPro ?? false ? '사용 중' : 'Pro로 바꾸기 (모의 결제)'),
              ),
            ),
          ],
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_message!),
          ),
        const SizedBox(height: 16),
        Text(
          '요금 수치는 가안입니다(설계서 미결정 5). AI 크레딧은 쓴 토큰만큼 줄어듭니다(1크레딧 = AI 원가 1원). 실제 결제는 하지 않습니다.',
          style: theme.textTheme.muted,
        ),
      ],
    );
  }
}
