import 'dart:async';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';

/// 로그인 상태. Supabase 설정이 없으면 늘 null (앱의 기기 안 기능은 로그인 없이 된다).
final authUserProvider = StreamProvider<User?>((ref) {
  if (!SupabaseConfig.isConfigured) return Stream.value(null);
  final auth = Supabase.instance.client.auth;
  return auth.onAuthStateChange
      .map((state) => state.session?.user)
      .startWithValue(auth.currentUser);
});

/// 서버가 정한 요금제와 이번 달 AI 크레딧 (RLS: 본인 행만 읽힘). 설계서 6 v1.3.30.
///
/// 차감은 서버가 실제 토큰으로 한다. 앱은 보여 주기만 한다 — 한도 값도 서버 환경변수가 정하고,
/// 아래 숫자는 가안(무료 60·Pro 3,000)을 화면에 보여 주는 용도다.
class PlanInfo {
  const PlanInfo({
    required this.plan,
    this.renewsAt,
    required this.spentCredits,
  });

  final String plan;
  final DateTime? renewsAt;

  /// 이번 달 쓴 크레딧 (1크레딧 = API 원가 1원).
  final double spentCredits;

  static const freeCredits = 60.0;
  static const proCredits = 3000.0;

  /// 질문 1회 어림 (요금제분석: 무료 60크레딧 ≈ 질문 23회).
  static const creditsPerQuestion = 2.6;

  double get limitCredits => isPro ? proCredits : freeCredits;

  double get remainingCredits =>
      (limitCredits - spentCredits).clamp(0, limitCredits);

  int get remainingQuestions => (remainingCredits / creditsPerQuestion).floor();

  bool get isPro =>
      plan == 'pro' && (renewsAt == null || renewsAt!.isAfter(DateTime.now()));
}

final planProvider = FutureProvider<PlanInfo?>((ref) async {
  final user = ref.watch(authUserProvider).value;
  if (user == null) return null;
  final db = Supabase.instance.client;
  final profile = await db
      .from('profiles')
      .select('plan, plan_renews_at')
      .eq('id', user.id)
      .maybeSingle();
  final now = DateTime.now().toUtc();
  final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
  final usage = await db
      .from('ai_usage')
      .select('spent_micro, reserved_micro')
      .eq('user_id', user.id)
      .eq('month', month)
      .maybeSingle();
  final micro =
      ((usage?['spent_micro'] as num?) ?? 0) +
      ((usage?['reserved_micro'] as num?) ?? 0);
  return PlanInfo(
    plan: '${profile?['plan'] ?? 'free'}',
    renewsAt: DateTime.tryParse('${profile?['plan_renews_at'] ?? ''}'),
    spentCredits: micro / 1000000,
  );
});

class AiGatewayException implements Exception {
  const AiGatewayException(this.message, {this.status});

  final String message;
  final int? status;

  bool get isLimit => status == 402;

  bool get isRateLimit => status == 429;

  @override
  String toString() => message;
}

class ChatAnswer {
  const ChatAnswer({
    required this.answer,
    required this.usedNoteIds,
    this.remainingCredits,
  });

  final String answer;
  final List<String> usedNoteIds;

  /// 서버가 정산한 뒤 남은 크레딧.
  final double? remainingCredits;
}

/// AI 게이트웨이 (경로 B, 설계서 5.3·6). 질문과 근거 노트 일부만 보내고, 서버는 내용을 저장하지 않는다.
class AiGateway {
  const AiGateway();

  FunctionsClient get _functions => Supabase.instance.client.functions;

  Future<Map<String, dynamic>> _invoke(
    String fn,
    Map<String, dynamic> body,
  ) async {
    if (!SupabaseConfig.isConfigured) {
      throw const AiGatewayException('서버 설정 전입니다 (env/supabase.json).');
    }
    if (Supabase.instance.client.auth.currentUser == null) {
      throw const AiGatewayException('AI 질문은 로그인한 뒤 쓸 수 있습니다.', status: 401);
    }
    try {
      // 함수 응답 한도(150초)보다 길게 기다리지 않는다 (S-9).
      // 보내기 직전에 모든 글자 칸의 비밀값을 가린다 (질문·노트·규칙·검증할 답, 11/11 K-31).
      final response = await _functions
          .invoke(fn, body: maskSecretsDeep(body))
          .timeout(const Duration(seconds: 90));
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (e) {
      final details = e.details;
      final message = details is Map && details['error'] != null
          ? '${details['error']}'
          : '서버 응답 오류 (${e.status})';
      throw AiGatewayException(message, status: e.status);
    } on TimeoutException {
      throw const AiGatewayException('서버가 응답하지 않습니다. 잠시 뒤 다시 시도하세요.');
    } on SocketException {
      throw const AiGatewayException('인터넷에 연결되어 있지 않습니다.');
    } on Object catch (e) {
      throw AiGatewayException('서버에 요청하지 못했습니다: $e');
    }
  }

  /// 질문 → 답. 근거가 3개 미만이면 검색어를 다시 만들어 한 번 더 찾는다. 두 호출 모두 쓴 토큰만큼 크레딧이 빠진다.
  Future<(ChatAnswer, ChatContext)> ask(
    Vault vault,
    SearchIndex index,
    String question, {
    String? topic,
  }) async {
    var context = ChatContext.build(vault, index, question, topic: topic);
    // 초안만 있으면 다시 찾아도 근거가 없다 — 크레딧이 드는 검색어 만들기를 부르지 않는다 (설계서_프롬프트이후 4.1).
    final drafts = AppConfig.load().usesLegacy(AppConfig.legacyDrafts);
    if (context.needsExpansion && index.notes().any((d) => drafts || !d.isDraft)) {
      final expanded = await _invoke('ai-chat', {
        'task': 'expand_query',
        'question': question,
      });
      context = ChatContext.build(
        vault,
        index,
        question,
        topic: topic,
        extraQueries: [
          for (final q in (expanded['queries'] as List? ?? [])) '$q',
        ],
      );
    }
    final data = await _invoke('ai-chat', {
      'task': 'answer',
      'question': question,
      'notes': [for (final n in context.notes) n.toJson()],
      'lessons': [
        for (final l in context.lessons)
          {'trigger': l.trigger, 'action': l.action, 'reason': l.reason},
      ],
    });
    return (
      ChatAnswer(
        answer: '${data['answer'] ?? ''}',
        usedNoteIds: [
          for (final id in (data['usedNoteIds'] as List? ?? [])) '$id',
        ],
        remainingCredits: (data['remainingMicro'] as num?) == null
            ? null
            : (data['remainingMicro'] as num) / 1000000,
      ),
      context,
    );
  }

  /// 검증 에이전트 (설계서 5.4). mode: correction | answer | missed.
  Future<Map<String, dynamic>> verify(Map<String, dynamic> body) =>
      _invoke('ai-verify', body);

  Future<void> mockCheckout() => _invoke('mock-checkout', {});
}

final aiGatewayProvider = Provider<AiGateway>((ref) => const AiGateway());

extension<T> on Stream<T> {
  Stream<T> startWithValue(T value) async* {
    yield value;
    yield* this;
  }
}
