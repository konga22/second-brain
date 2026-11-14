import 'dart:async';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/app_config_provider.dart';
import '../../shared/date_text.dart';
import '../../core/brain_providers.dart';
import '../../core/claude_code.dart';
import '../../shared/page_header.dart';

/// AI가 배운 것 (설계서 3절 `/lessons`, 5.4): 실수 노트·교정 diff·회귀 시험·검사 기준.
/// 승인 대기 규칙은 여기서 승인해야 훅이 대화에 넣는다.
class LessonsPage extends ConsumerStatefulWidget {
  const LessonsPage({super.key});

  @override
  ConsumerState<LessonsPage> createState() => _LessonsPageState();
}

class _LessonsPageState extends ConsumerState<LessonsPage> {
  LessonStatus _tab = LessonStatus.pending;
  bool _isFinding = false;
  String _step = '';
  Duration _elapsed = Duration.zero;
  String? _findResult;
  String? _findError;
  Process? _process;

  @override
  void dispose() {
    _process?.kill();
    super.dispose();
  }

  /// 놓친 교정 줍기 (설계서_프롬프트이후 5.10 ①). 대화 중에는 교정이 실수 노트로 잘 넘어가지 않아서(8번 조사: 11/10 뒤 0/13),
  /// 지난 대화의 사용자 말을 다른 맥락(싼 모델)이 나중에 훑는다. 올린 것은 모두 승인 대기다.
  Future<void> _onFindMissed() async {
    final budget = ClaudeCode.correctionsBudgetUsd.toStringAsFixed(2);
    final isConfirmed = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('놓친 교정 찾기'),
        description: Text(
          '이 맥의 Claude Code가 지난 대화에서 사용자 말과 바로 앞 AI 답 끝만 읽고, AI가 놓친 교정을 규칙 후보로 '
          '승인 대기에 올립니다(한 번에 최대 ${ClaudeCode.correctionsMaxLessons}개, 바로 적용하지 않음). '
          '싼 모델(Haiku)을 쓰고 한 번에 최대 $budget달러까지 씁니다. '
          '이미 훑은 대화는 다시 읽지 않습니다. 우리 서버는 거치지 않습니다.',
        ),
        actions: [
          ShadButton.outline(onPressed: () => Navigator.of(context).pop(false), child: const Text('취소')),
          ShadButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('동의하고 찾기')),
        ],
      ),
    );
    if (isConfirmed != true) return;
    final before = ref.read(lessonsProvider).where((l) => l.status == LessonStatus.pending).length;
    final startedAt = DateTime.now();
    final timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed = DateTime.now().difference(startedAt));
    });
    setState(() {
      _isFinding = true;
      _step = 'Claude Code 시작 중';
      _findResult = null;
      _findError = null;
    });
    String? error;
    try {
      final result = await ref.read(claudeCodeProvider).findMissedCorrections(
        onStart: (p) => _process = p,
        onStep: (step) {
          if (mounted) setState(() => _step = step);
        },
      );
      if (!result.ok) {
        error = result.needsLogin ? '터미널에서 claude를 실행해 /login 한 뒤 다시 시도하세요.' : '찾지 못했습니다: ${result.message}';
      }
    } on Object catch (e) {
      error = '찾지 못했습니다: $e';
    } finally {
      timer.cancel();
      _process = null;
      bumpVault(ref);
    }
    if (!mounted) return;
    final after = ref.read(lessonsProvider).where((l) => l.status == LessonStatus.pending).length;
    setState(() {
      _isFinding = false;
      _findError = error;
      if (error == null) {
        _findResult = after > before
            ? '승인 대기에 ${after - before}개를 올렸습니다. 읽어 보고 맞는 것만 승인하세요.'
            : '새로 올린 규칙 후보가 없습니다.';
        if (after > before) _tab = LessonStatus.pending;
      }
    });
  }

  void _onSetStatus(Lesson lesson, LessonStatus status) {
    ref.read(lessonStoreProvider).setStatus(lesson.id, status, batch: newBatchId());
    bumpVault(ref);
  }

  Future<void> _onNew() async {
    // 7칸을 쓰다 바깥 클릭 한 번에 사라지지 않게 (11/11 K-24)
    await showShadDialog<void>(context: context, barrierDismissible: false, builder: (_) => const _NewLessonDialog());
    bumpVault(ref);
  }

  /// 비슷한 두 규칙을 한 문장으로 (설계서_프롬프트이후 4.5). 최근 쪽을 남겨 세션 시작 목록에서 밀려나지 않게 한다.
  Future<void> _onMerge(Lesson a, Lesson b) async {
    final (keep, drop) = Lesson.recentFirst(a, b) <= 0 ? (a, b) : (b, a);
    await showShadDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MergeLessonDialog(keep: keep, drop: drop),
    );
    bumpVault(ref);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final lessons = ref.watch(lessonsProvider);
    final store = ref.watch(lessonStoreProvider);
    ref.watch(vaultRevisionProvider);
    final shown = lessons.where((l) => l.status == _tab).toList();
    final active = lessons.where((l) => l.status == LessonStatus.active).toList();
    final isLegacyOrder = ref.watch(appConfigProvider).usesLegacy(AppConfig.legacyLessons);
    final tests = store.allTests();
    final checklist = store.checklist();
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
      children: [
        PageHeader(
          title: 'AI가 배운 것',
          actions: [
            if (_isFinding)
              ShadButton.outline(size: ShadButtonSize.sm, onPressed: () => _process?.kill(), child: const Text('멈추기'))
            else
              ShadButton.outline(
                size: ShadButtonSize.sm,
                leading: const Icon(LucideIcons.search, size: 14),
                onPressed: _onFindMissed,
                child: const Text('놓친 교정 찾기'),
              ),
            const SizedBox(width: 6),
            ShadButton(
              size: ShadButtonSize.sm,
              leading: const Icon(LucideIcons.plus, size: 14),
              onPressed: _onNew,
              child: const Text('새 규칙'),
            ),
          ],
        ),
        if (_isFinding) ...[
          const SizedBox(height: 10),
          const ShadProgress(),
          const SizedBox(height: 4),
          Text('$_step · ${_elapsed.inSeconds}초', style: theme.textTheme.muted),
        ],
        if (_findResult != null || _findError != null) ...[
          const SizedBox(height: 8),
          Text(
            _findError ?? _findResult!,
            style: TextStyle(
              fontSize: 13,
              color: _findError != null ? AppColors.of(context).danger : AppColors.of(context).text,
            ),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          '교정에서 나온 규칙(언제 → 무엇을 → 왜)입니다. 적용 중인 규칙은 Claude Code 세션 시작 때 한 줄씩 늘 들어가고'
          '(최대 ${LessonStore.maxSessionLessons}개, ${isLegacyOrder ? '번호 순' : '최근에 만들었거나 다시 교정된 것부터'}), '
          '요청과 맞으면 이유까지 다시 붙습니다(최대 3개).',
          style: theme.textTheme.muted,
        ),
        if (active.length > LessonStore.maxSessionLessons) ...[
          const SizedBox(height: 12),
          MergeNotice(active: active, isLegacyOrder: isLegacyOrder, onMerge: _onMerge),
        ],
        const SizedBox(height: 16),
        Wrap(
          runSpacing: 4,
          children: [
            for (final status in LessonStatus.values)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: (status == _tab ? ShadButton.secondary : ShadButton.ghost)(
                  size: ShadButtonSize.sm,
                  onPressed: () => setState(() => _tab = status),
                  child: Text('${status.label} ${lessons.where((l) => l.status == status).length}'),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              switch (_tab) {
                LessonStatus.pending => '승인을 기다리는 규칙이 없습니다.',
                LessonStatus.active => '적용 중인 규칙이 없습니다. 대화에서 AI 답을 고치면 검증 에이전트가 규칙 후보를 만듭니다.',
                LessonStatus.archived => '보관한 규칙이 없습니다.',
              },
              style: theme.textTheme.muted,
            ),
          ),
        for (final lesson in shown)
          _LessonCard(
            lesson: lesson,
            onApprove: lesson.status == LessonStatus.pending
                ? () => _onSetStatus(lesson, LessonStatus.active)
                : null,
            onArchive: lesson.status != LessonStatus.archived
                ? () => _onSetStatus(lesson, LessonStatus.archived)
                : null,
            onRestore: lesson.status == LessonStatus.archived
                ? () => _onSetStatus(lesson, LessonStatus.active)
                : null,
          ),
        const SizedBox(height: 24),
        Text('회귀 시험 ${tests.length}/${LessonStore.maxTests}', style: theme.textTheme.small),
        Text('규칙·검사 기준을 바꿀 때 다시 돌려, 이전에 통과하던 사례가 깨지면 변경을 거절합니다.', style: theme.textTheme.muted),
        const SizedBox(height: 6),
        for (final t in tests)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('${t.id} (${t.lesson})  ${t.question}  →  통과: ${t.expect}', style: const TextStyle(fontSize: 12)),
          ),
        const SizedBox(height: 20),
        Text('검사 기준 ${checklist.length}/${LessonStore.maxChecklist}', style: theme.textTheme.small),
        Text('검증 에이전트가 쓰는 확인 항목입니다. 검증이 놓친 실수에서 회귀 시험을 통과할 때만 늘어납니다.', style: theme.textTheme.muted),
        const SizedBox(height: 6),
        if (checklist.isEmpty)
          Text('기본: 근거 노트에 있는 내용인가 · diff와 맞는가 · 규칙의 action을 따랐는가', style: theme.textTheme.muted),
        for (final (i, item) in checklist.indexed) Text('${i + 1}. $item', style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

/// "합치기 필요" (설계서_프롬프트이후 4.5): 적용 중 규칙이 30개를 넘으면 오래된 규칙이 세션 시작 안내에서 빠진다.
/// 비슷한 규칙 쌍(단어가 겹치는 것, AI 호출 없음)을 보여 주고 사용자가 한 문장으로 합친다.
class MergeNotice extends StatelessWidget {
  const MergeNotice({super.key, required this.active, required this.isLegacyOrder, required this.onMerge});

  final List<Lesson> active;
  final bool isLegacyOrder;
  final void Function(Lesson a, Lesson b) onMerge;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final rest = active.length - LessonStore.maxSessionLessons;
    final pairs = LessonStore.similarPairs(active);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.warning),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('합치기 필요', style: theme.textTheme.small),
          const SizedBox(height: 2),
          Text(
            '적용 중 규칙이 ${active.length}개라 세션 시작 안내에 다 들어가지 않습니다. '
            '${isLegacyOrder ? '번호가 큰(최근)' : '오래되고 다시 교정되지 않은'} 규칙 $rest개는 요청과 맞을 때만 붙습니다. '
            '비슷한 규칙을 한 문장으로 합치거나 안 쓰는 규칙을 보관하세요.',
            style: theme.textTheme.muted,
          ),
          const SizedBox(height: 8),
          if (pairs.isEmpty) Text('비슷한 규칙 쌍을 찾지 못했습니다.', style: theme.textTheme.muted),
          for (final (a, b, _) in pairs)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${a.id}  ${a.line}', style: const TextStyle(fontSize: 12)),
                        Text('${b.id}  ${b.line}', style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ShadButton.outline(size: ShadButtonSize.sm, onPressed: () => onMerge(a, b), child: const Text('합치기')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 두 규칙의 문장을 이어 채워 두고, 사용자가 한 문장으로 고쳐 저장한다. [keep]을 고치고 [drop]은 보관한다.
class _MergeLessonDialog extends ConsumerStatefulWidget {
  const _MergeLessonDialog({required this.keep, required this.drop});

  final Lesson keep;
  final Lesson drop;

  @override
  ConsumerState<_MergeLessonDialog> createState() => _MergeLessonDialogState();
}

class _MergeLessonDialogState extends ConsumerState<_MergeLessonDialog> {
  late final _fields = {
    'trigger': TextEditingController(text: _both(widget.keep.trigger, widget.drop.trigger)),
    'action': TextEditingController(text: _both(widget.keep.action, widget.drop.action)),
    'reason': TextEditingController(text: _both(widget.keep.reason, widget.drop.reason)),
  };
  String? _error;

  static String _both(String a, String b) => a.trim() == b.trim() ? a : '$a / $b';

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onSave() {
    try {
      ref.read(lessonStoreProvider).merge(
        widget.keep.id,
        widget.drop.id,
        trigger: _fields['trigger']!.text,
        action: _fields['action']!.text,
        reason: _fields['reason']!.text,
        batch: newBatchId(),
      );
      Navigator.of(context).pop();
    } on NoteStoreException catch (e) {
      setState(() => _error = e.message);
    }
  }

  // 칸 이름을 왼쪽에 늘 보인다: 글이 채워지면 안내 글(placeholder)이 사라져 어느 칸인지 모른다 (11/13 화면 검토)
  Widget _input(String key, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        SizedBox(width: 52, child: Text(label, style: ShadTheme.of(context).textTheme.muted)),
        Expanded(child: ShadInput(controller: _fields[key], placeholder: Text(label))),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text('규칙 합치기'),
      description: Text(
        // id 끝 글자에 따라 조사가 바뀌므로 "규칙을/규칙은"으로 쓴다 ("L-0004을" 같은 틀린 조사 방지)
        '${widget.keep.id} 규칙을 고쳐 남기고, ${widget.drop.id} 규칙은 보관합니다(복원 가능). '
        '두 규칙 문장을 이어 두었으니 한 문장으로 고쳐 저장하세요.',
      ),
      constraints: const BoxConstraints(maxWidth: 620),
      actions: [
        ShadButton.outline(onPressed: () => Navigator.of(context).pop(), child: const Text('취소')),
        ShadButton(onPressed: _onSave, child: const Text('합쳐 저장')),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _input('trigger', '언제'),
          _input('action', '무엇을'),
          _input('reason', '왜'),
          if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xffdc2626))),
        ],
      ),
    );
  }
}

class _LessonCard extends StatelessWidget {
  const _LessonCard({required this.lesson, this.onApprove, this.onArchive, this.onRestore});

  final Lesson lesson;
  final VoidCallback? onApprove;
  final VoidCallback? onArchive;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(lesson.id, style: theme.textTheme.muted),
              const SizedBox(width: 8),
              ShadBadge.outline(child: Text(lesson.source == 'explicit' ? '직접 교정' : '자동 감지')),
              const SizedBox(width: 8),
              // 날짜 표시 (설계서 3.0): 만듦은 변경 기록, 없으면 파일 시각
              Consumer(
                builder: (context, ref, _) {
                  final created = ref.watch(firstSeenProvider)[lesson.id] ??
                      ref.watch(lessonsFileTimeProvider)[lesson.id];
                  return Text(
                    [
                      if (created != null) '만듦 ${stamp(created)}',
                      if (lesson.lastSeen != null) '마지막 적용 ${dayStamp(lesson.lastSeen!)}',
                    ].join(' · '),
                    style: theme.textTheme.muted.copyWith(fontSize: 11),
                  );
                },
              ),
              const Spacer(),
              Text('지킴 ${lesson.kept} · 다시 교정 ${lesson.recorrected}', style: theme.textTheme.muted),
            ],
          ),
          const SizedBox(height: 6),
          Text('${lesson.trigger}  →  ${lesson.action}', style: theme.textTheme.small),
          const SizedBox(height: 2),
          Text('왜: ${lesson.reason}', style: theme.textTheme.muted),
          if (lesson.diff.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: colors.surfaceRaised, borderRadius: BorderRadius.circular(6)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in lesson.diff.split('\n'))
                    Text(
                      line,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'Menlo',
                        color: line.startsWith('+')
                            ? colors.success
                            : (line.startsWith('-') ? colors.danger : colors.textMuted),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (lesson.tests.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('회귀 시험: ${lesson.tests.join(', ')}', style: theme.textTheme.muted),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (onApprove != null)
                ShadButton(size: ShadButtonSize.sm, onPressed: onApprove, child: const Text('승인 → 적용')),
              if (onRestore != null)
                ShadButton.outline(size: ShadButtonSize.sm, onPressed: onRestore, child: const Text('복원')),
              const SizedBox(width: 6),
              if (onArchive != null)
                ShadButton.ghost(size: ShadButtonSize.sm, onPressed: onArchive, child: const Text('보관')),
            ],
          ),
        ],
      ),
    );
  }
}

class _NewLessonDialog extends ConsumerStatefulWidget {
  const _NewLessonDialog();

  @override
  ConsumerState<_NewLessonDialog> createState() => _NewLessonDialogState();
}

class _NewLessonDialogState extends ConsumerState<_NewLessonDialog> {
  final _fields = {
    for (final key in ['trigger', 'action', 'reason', 'before', 'after', 'question', 'expect'])
      key: TextEditingController(),
  };
  String? _error;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _v(String key) => _fields[key]!.text.trim();

  void _onSave() {
    try {
      final diff = [
        if (_v('before').isNotEmpty) '- ${_v('before')}',
        if (_v('after').isNotEmpty) '+ ${_v('after')}',
      ].join('\n');
      ref.read(lessonStoreProvider).add(
        trigger: _v('trigger'),
        action: _v('action'),
        reason: _v('reason'),
        diff: diff,
        // 사용자가 직접 쓴 규칙은 직접 교정이라 바로 적용한다.
        status: LessonStatus.active,
        question: _v('question'),
        bad: _v('before'),
        expect: _v('expect'),
        batch: newBatchId(),
      );
      Navigator.of(context).pop();
    } on NoteStoreException catch (e) {
      setState(() => _error = e.message);
    }
  }

  // 칸 이름을 왼쪽에 늘 보인다: 글이 채워지면 안내 글(placeholder)이 사라져 어느 칸인지 모른다 (11/13 화면 검토)
  Widget _input(String key, String label, String hint) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        SizedBox(width: 76, child: Text(label, style: ShadTheme.of(context).textTheme.muted)),
        Expanded(child: ShadInput(controller: _fields[key], placeholder: Text(hint))),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text('새 규칙'),
      description: const Text('언제 → 무엇을 → 왜. 회귀 시험(질문·통과 조건)을 함께 적으면 나중에 규칙이 서로 부딪히지 않게 확인합니다.'),
      constraints: const BoxConstraints(maxWidth: 620),
      actions: [
        ShadButton.outline(onPressed: () => Navigator.of(context).pop(), child: const Text('취소')),
        ShadButton(onPressed: _onSave, child: const Text('저장 (적용)')),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _input('trigger', '언제', '예: 결제 코드를 수정할 때'),
          _input('action', '무엇을', '예: 테스트 키로 먼저 확인한다'),
          _input('reason', '왜', '예: 실제 키로 시험해 결제가 나간 적이 있음'),
          _input('before', 'AI가 한 것', 'diff 앞, 선택'),
          _input('after', '고친 것', 'diff 뒤, 선택'),
          _input('question', '시험 질문', '회귀 시험 질문 (선택, 예: 결제 모듈에 새 카드사를 붙여 줘)'),
          _input('expect', '통과 조건', '선택, 예: 테스트 키로 먼저 확인한다고 답한다'),
          if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xffdc2626))),
        ],
      ),
    );
  }
}
