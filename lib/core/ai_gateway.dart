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

/// 서버가 정한 요금제와 이번 달 사용량 (RLS: 본인 행만 읽힘).
class PlanInfo {
  const PlanInfo({required this.plan, this.renewsAt, required this.used});

  final String plan;
  final DateTime? renewsAt;
  final int used;

  bool get isPro => plan == 'pro' && (renewsAt == null || renewsAt!.isAfter(DateTime.now()));
}

final planProvider = FutureProvider<PlanInfo?>((ref) async {
  final user = ref.watch(authUserProvider).value;
  if (user == null) return null;
  final db = Supabase.instance.client;
  final profile = await db.from('profiles').select('plan, plan_renews_at').eq('id', user.id).maybeSingle();
  final now = DateTime.now().toUtc();
  final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
  final usage = await db.from('usage').select('ai_calls').eq('user_id', user.id).eq('month', month).maybeSingle();
  return PlanInfo(
    plan: '${profile?['plan'] ?? 'free'}',
    renewsAt: DateTime.tryParse('${profile?['plan_renews_at'] ?? ''}'),
    used: (usage?['ai_calls'] as int?) ?? 0,
  );
});

class AiGatewayException implements Exception {
  const AiGatewayException(this.message, {this.status});

  final String message;
  final int? status;

  bool get isLimit => status == 402;

  @override
  String toString() => message;
}

class ChatAnswer {
  const ChatAnswer({required this.answer, required this.usedNoteIds, this.remaining});

  final String answer;
  final List<String> usedNoteIds;
  final int? remaining;
}

/// AI 게이트웨이 (경로 B, 설계서 5.3·6). 질문과 근거 노트 일부만 보내고, 서버는 내용을 저장하지 않는다.
class AiGateway {
  const AiGateway();

  FunctionsClient get _functions => Supabase.instance.client.functions;

  Future<Map<String, dynamic>> _invoke(String fn, Map<String, dynamic> body) async {
    if (!SupabaseConfig.isConfigured) {
      throw const AiGatewayException('서버 설정 전입니다 (env/supabase.json).');
    }
    if (Supabase.instance.client.auth.currentUser == null) {
      throw const AiGatewayException('AI 질문은 로그인한 뒤 쓸 수 있습니다.', status: 401);
    }
    try {
      final response = await _functions.invoke(fn, body: body);
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (e) {
      final details = e.details;
      final message = details is Map && details['error'] != null
          ? '${details['error']}'
          : '서버 응답 오류 (${e.status})';
      throw AiGatewayException(message, status: e.status);
    }
  }

  /// 질문 → 답. 근거가 3개 미만이면 검색어를 다시 만들어 한 번 더 찾는다 (같은 질문의 사용량 1회).
  Future<(ChatAnswer, ChatContext)> ask(
    Vault vault,
    SearchIndex index,
    String question,
  ) async {
    var context = ChatContext.build(vault, index, question);
    var counted = false;
    if (context.needsExpansion && index.notes().isNotEmpty) {
      final expanded = await _invoke('ai-chat', {
        'task': 'expand_query',
        'question': question,
        'countUsage': true,
      });
      counted = true;
      context = ChatContext.build(
        vault,
        index,
        question,
        extraQueries: [for (final q in (expanded['queries'] as List? ?? [])) '$q'],
      );
    }
    final data = await _invoke('ai-chat', {
      'task': 'answer',
      'question': question,
      'countUsage': !counted,
      'notes': [for (final n in context.notes) n.toJson()],
      'lessons': [
        for (final l in context.lessons) {'trigger': l.trigger, 'action': l.action, 'reason': l.reason},
      ],
    });
    return (
      ChatAnswer(
        answer: '${data['answer'] ?? ''}',
        usedNoteIds: [for (final id in (data['usedNoteIds'] as List? ?? [])) '$id'],
        remaining: data['remaining'] as int?,
      ),
      context,
    );
  }

  /// 검증 에이전트 (설계서 5.4). mode: correction | answer | missed.
  Future<Map<String, dynamic>> verify(Map<String, dynamic> body) => _invoke('ai-verify', body);

  Future<void> mockCheckout() => _invoke('mock-checkout', {});
}

final aiGatewayProvider = Provider<AiGateway>((ref) => const AiGateway());

extension<T> on Stream<T> {
  Stream<T> startWithValue(T value) async* {
    yield value;
    yield* this;
  }
}
