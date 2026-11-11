import 'package:brain_core/brain_core.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/ai_gateway.dart';
import '../../core/brain_providers.dart';
import '../../shared/page_header.dart';
import '../auth/login_dialog.dart';
import '../../shared/safe_set_state.dart';

/// AI 질문 (경로 B, 설계서 3절 `/chat`·5.3·5.4): 위키 기반 답, 근거 노트, [틀렸어].
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _Turn {
  _Turn(this.question);

  final String question;
  String? answer;
  List<String> usedNoteIds = const [];
  List<Lesson> lessons = const [];
  String? error;
  String? verdict;
  bool isWorking = true;
}

class _ChatPageState extends ConsumerState<ChatPage> with SafeSetState<ChatPage> {
  final _input = TextEditingController();
  final _turns = <_Turn>[];

  /// 답할 범위: 주제 폴더(뇌) 하나. 그 폴더에서 먼저 찾고 모자라면 전체에서 채운다.
  String? _topic;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _onAsk() async {
    final question = _input.text.trim();
    if (question.isEmpty) return;
    _input.clear();
    final turn = _Turn(question);
    setState(() => _turns.add(turn));
    final gateway = ref.read(aiGatewayProvider);
    final vault = ref.read(vaultProvider);
    try {
      final (answer, context) = await gateway.ask(
        vault,
        ref.read(searchIndexProvider),
        question,
        topic: _topic,
      );
      var text = answer.answer;
      // 실수 노트가 들어간 답이면 검증해서, 어겼으면 한 번 다시 쓴다 (설계서 5.3).
      // 검증이 실패해도(하루 한도·서버 오류) 이미 받은 답은 버리지 않는다 — 크레딧은 이미 빠졌다 (11/11 검토 S-4).
      if (context.lessons.isNotEmpty) {
        Map<String, dynamic>? check;
        try {
          check = await gateway.verify({
            'mode': 'answer',
            'question': question,
            'answer': text,
            'lessons': [
              for (final l in context.lessons)
                {'id': l.id, 'trigger': l.trigger, 'action': l.action},
            ],
            // 검사 기준(검증이 놓친 실수에서 생긴 항목)도 함께 본다. 예전에는 쌓기만 하고 읽는 곳이 없었다 (11/11 K-36).
            'checklist': ref.read(lessonStoreProvider).checklist(),
          });
        } on AiGatewayException catch (e) {
          turn.verdict = '검증하지 못했습니다 (${e.message}). 아래 답은 검증 전입니다.';
        }
        if (check == null) {
          // 검증 전 답을 그대로 보여 준다
        } else if (check['verdict'] == 'rewrite' &&
            check['fixedAnswer'] != null) {
          text = '${check['fixedAnswer']}';
          turn.verdict = '검증: 규칙을 어겨 다시 썼습니다 (${check['reason']})';
        } else {
          final store = ref.read(lessonStoreProvider);
          for (final l in context.lessons) {
            store.recordEvidence(l.id, kept: true);
          }
        }
      }
      turn
        ..answer = text
        ..usedNoteIds = answer.usedNoteIds
        ..lessons = context.lessons;
      appendChatLog(
        vault,
        question: question,
        answer: text,
        usedNoteIds: answer.usedNoteIds,
      );
      if (answer.usedNoteIds.isNotEmpty) {
        ref
            .read(selectedNoteProvider.notifier)
            .select(answer.usedNoteIds.first);
      }
      ref.invalidate(planProvider);
    } on AiGatewayException catch (e) {
      turn.error = e.message;
    } on Object catch (e) {
      turn.error = '답을 받지 못했습니다: $e';
    } finally {
      if (mounted) setState(() => turn.isWorking = false);
    }
  }

  /// [틀렸어]: 고친 내용을 받아 검증 에이전트가 규칙 후보인지 판단한다 (설계서 5.4).
  Future<void> _onWrong(_Turn turn) async {
    final controller = TextEditingController();
    // 교정 문장을 쓰다 바깥 클릭 한 번에 사라지지 않게 (11/11 K-24)
    final correction = await showShadDialog<String>(
      barrierDismissible: false,
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('어디가 틀렸나요?'),
        description: const Text(
          '맞는 답이나 고칠 점을 적어 주세요. 일반 규칙이 될 만하면 검증 뒤 실수 노트로 남습니다.',
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('보내기'),
          ),
        ],
        child: ShadTextarea(controller: controller, minHeight: 100),
      ),
    );
    controller.dispose();
    if (correction == null || correction.trim().isEmpty) return;
    setState(() => turn.verdict = '검증 중…');
    final store = ref.read(lessonStoreProvider);
    try {
      final result = await ref.read(aiGatewayProvider).verify({
        'mode': 'correction',
        'question': turn.question,
        'answer': turn.answer,
        'reaction': correction,
        'diff': '- ${turn.answer?.split('\n').first ?? ''}\n+ $correction',
        'lessons': [
          for (final l in store.all(status: LessonStatus.active))
            {'id': l.id, 'trigger': l.trigger, 'action': l.action},
        ],
        'tests': [
          for (final t in store.testsFor(turn.question))
            {'id': t.id, 'question': t.question, 'expect': t.expect},
        ],
        'checklist': store.checklist(),
      });
      final verdict = '${result['verdict']}';
      final lesson = result['lesson'] as Map?;
      final test = result['test'] as Map?;
      String message;
      if (verdict == 'lesson' && lesson != null) {
        final (id, testId) = store.add(
          trigger: '${lesson['trigger']}',
          action: '${lesson['action']}',
          reason: '${lesson['reason']}',
          diff: '- ${turn.answer?.split('\n').first ?? ''}\n+ $correction',
          status: LessonStatus.active, // 직접 교정 + 검증·시험 통과
          question: test == null ? null : '${test['question']}',
          bad: test == null ? null : '${test['bad']}',
          expect: test == null ? null : '${test['expect']}',
          batch: newBatchId(),
        );
        message =
            '실수 노트 $id로 저장했습니다${testId == null ? '' : ' (회귀 시험 $testId)'}: ${lesson['trigger']} → ${lesson['action']}';
        bumpVault(ref);
      } else {
        message = switch (verdict) {
          'merge' => '기존 규칙과 같습니다. 다시 교정된 것으로 기록했습니다.',
          'not_correction' => '일회성 내용이라 규칙으로 만들지 않았습니다.',
          'ask' => '되묻기: ${result['question']}',
          'reject' =>
            '거절: 이전 사례(${(result['brokenTests'] as List?)?.join(', ')})와 충돌합니다.',
          _ => '${result['reason']}',
        };
      }
      appendChatLog(
        ref.read(vaultProvider),
        question: turn.question,
        answer: turn.answer ?? '',
        usedNoteIds: turn.usedNoteIds,
        correction: correction,
      );
      setState(() => turn.verdict = message);
    } on AiGatewayException catch (e) {
      setState(() => turn.verdict = '검증 실패: ${e.message}');
    } on Object catch (e) {
      // 실수 노트 저장 실패 등: "검증 중…"에 멈추지 않는다 (11/11 K-37)
      setState(() => turn.verdict = '검증 결과를 저장하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final user = ref.watch(authUserProvider).value;
    final plan = ref.watch(planProvider).value;
    final index = ref.watch(searchIndexProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 40, 32, 8),
          child: PageHeader(
            title: 'AI 질문',
            subtitle: user == null
                ? '로그인 필요'
                : '${plan?.isPro == true ? 'Pro' : '무료'} · 남은 크레딧 ${plan?.remainingCredits.toStringAsFixed(1) ?? '-'} (질문 약 ${plan?.remainingQuestions ?? 0}회)',
            actions: [
              if (user == null)
                ShadButton(
                  size: ShadButtonSize.sm,
                  onPressed: () => showLoginDialog(context),
                  child: const Text('로그인'),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 8),
          // 폴더가 많아도 높이가 늘지 않게 가로로 밀어 본다 (좁은 창에서 아래가 넘치지 않게).
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text('답할 범위', style: theme.textTheme.muted),
                const SizedBox(width: 4),
                for (final t in [
                  null,
                  ...ref.watch(searchIndexProvider).topics(),
                ])
                  (t == _topic ? ShadButton.secondary : ShadButton.ghost)(
                    size: ShadButtonSize.sm,
                    height: 26,
                    onPressed: () => setState(() => _topic = t),
                    child: Text(t ?? '모든 폴더'),
                  ),
                if (_topic != null)
                  Text(
                    '· $_topic 지식으로 먼저 답하고, 없으면 전체에서 찾습니다',
                    style: theme.textTheme.muted.copyWith(fontSize: 12),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            '내 노트 상위 5개와 맞는 실수 노트만 AI 게이트웨이로 보내 답을 받습니다. 질문·답은 이 맥의 chats/에만 남고 서버에는 저장하지 않습니다.',
            style: theme.textTheme.muted,
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(32, 16, 32, 16),
            children: [
              for (final turn in _turns) ...[
                Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8, left: 80),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.accentSoft,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(turn.question),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.only(bottom: 16, right: 80),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    border: Border.all(color: colors.border),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (turn.isWorking)
                        Text('노트를 찾고 답을 받는 중…', style: theme.textTheme.muted),
                      if (turn.error != null)
                        Text(
                          turn.error!,
                          style: TextStyle(color: colors.danger),
                        ),
                      if (turn.answer != null)
                        SelectableText(
                          turn.answer!,
                          style: const TextStyle(fontSize: 13, height: 1.6),
                        ),
                      if (turn.usedNoteIds.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            Text('근거', style: theme.textTheme.muted),
                            for (final id in turn.usedNoteIds)
                              GestureDetector(
                                onTap: () => ref
                                    .read(selectedNoteProvider.notifier)
                                    .select(id),
                                child: ShadBadge.outline(
                                  child: Text(
                                    '$id ${index.byId(id)?.title ?? ''}',
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (turn.lessons.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '적용한 규칙: ${turn.lessons.map((l) => l.id).join(', ')}',
                            style: theme.textTheme.muted,
                          ),
                        ),
                      if (turn.verdict != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            turn.verdict!,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.accentText,
                            ),
                          ),
                        ),
                      if (turn.answer != null)
                        Align(
                          alignment: Alignment.centerRight,
                          child: ShadButton.ghost(
                            size: ShadButtonSize.sm,
                            leading: const Icon(
                              LucideIcons.thumbsDown,
                              size: 13,
                            ),
                            onPressed: () => _onWrong(turn),
                            child: const Text('틀렸어'),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
          child: Row(
            children: [
              Expanded(
                child: ShadInput(
                  controller: _input,
                  enabled: user != null,
                  placeholder: Text(
                    user == null
                        ? '로그인하면 질문할 수 있습니다'
                        : '내 노트에 대해 물어보세요 (Enter)',
                  ),
                  onSubmitted: (_) => _onAsk(),
                ),
              ),
              const SizedBox(width: 8),
              ShadButton(
                enabled: user != null,
                onPressed: _onAsk,
                child: const Text('질문'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
