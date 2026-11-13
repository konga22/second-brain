import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../core/background_tasks.dart';
import '../../core/brain_providers.dart';

/// [폴더 정리] (설계서_프롬프트이후 5.1): 구역 밖(예전 방식) 노트를 구역/주제로 옮긴다.
/// "노트 / 지금 자리 / 제안 자리 / 제안 이름"을 보여 주고, 사용자가 모두 또는 골라서 승인한다.
/// 실행은 되돌리기 묶음 하나다(설정 > 되돌리기·휴지통에서 통째로 되돌림).
Future<void> showFolderTidy(BuildContext context) =>
    showShadDialog<void>(context: context, builder: (_) => const FolderTidyDialog());

/// [폴더 정리] 한 번 실행한 결과. [failure]가 있으면 중간에 멈췄다 (옮긴 [moved]개는 그 묶음으로 되돌린다).
typedef FolderTidyOutcome = ({int moved, List<MoveError> errors, int done, bool isStopped, Object? failure});

/// 덩어리 하나를 옮긴다 ([moveNotesInBackground]). 빈 목록 + [syncAfter]는 색인·자동 목차 맞추기만.
typedef FolderMoveChunk = Future<MoveResult> Function(List<FolderMove> chunk, {required bool syncAfter});

bool _never() => false;

/// [moves]를 [chunk]개씩 옮긴다. 화면과 따로 돈다 (설계서_프롬프트이후 5.1, 11/13 검토).
///
/// 예전에는 이 반복이 창 안에 있어, 옮기는 중에 창을 닫으면(Esc·바깥 누름) 다음 덩어리 앞의 `mounted` 확인에서 그냥 끝났다 →
/// 남은 노트는 안 옮겨지고, 마지막 색인·자동 목차 맞추기와 결과 안내도 빠졌다. 이제는
/// - 창이 닫혀도 끝까지 옮기고 ([onChunk]는 화면이 있을 때만 쓰면 된다)
/// - 멈추거나(isStopping) 중간에 실패해도 그때까지 옮긴 것으로 색인·자동 목차를 한 번 맞춘다
/// - 결과를 돌려줘 부르는 쪽이 창이 없으면 알림으로 보인다
Future<FolderTidyOutcome> runFolderTidy(
  List<FolderMove> moves, {
  required FolderMoveChunk moveChunk,
  bool Function() isStopping = _never,
  void Function(int done, List<MoveError> errors)? onChunk,
  int chunk = 200,
}) async {
  var moved = 0;
  var done = 0;
  var isSynced = false;
  Object? failure;
  final errors = <MoveError>[];
  try {
    for (var start = 0; start < moves.length; start += chunk) {
      final end = (start + chunk).clamp(0, moves.length);
      final isLast = end == moves.length;
      final result = await moveChunk(moves.sublist(start, end), syncAfter: isLast);
      moved += result.moved.length;
      done = end;
      errors.addAll(result.errors);
      isSynced = isLast;
      onChunk?.call(done, result.errors);
      if (isLast || isStopping()) break;
    }
  } on Object catch (e) {
    failure = e;
  }
  if (!isSynced) {
    try {
      await moveChunk(const [], syncAfter: true);
    } on Object catch (e) {
      failure ??= e;
    }
  }
  return (moved: moved, errors: errors, done: done, isStopped: failure == null && done < moves.length, failure: failure);
}

class FolderTidyDialog extends ConsumerStatefulWidget {
  const FolderTidyDialog({super.key});

  @override
  ConsumerState<FolderTidyDialog> createState() => _FolderTidyDialogState();
}

class _FolderTidyDialogState extends ConsumerState<FolderTidyDialog> {
  /// 한 번에 옮기는 수: 덩어리마다 진행을 보이고 [멈추기]를 받는다.
  static const _chunk = 200;

  ({List<FolderProposal> proposals, Map<String, int> oversized, Map<String, List<String>> zoneTopics})? _plan;
  String? _error;
  var _done = 0;
  var _total = 0;
  var _isRunning = false;
  var _isStopping = false;
  String? _result;
  final _errors = <MoveError>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final vault = ref.read(vaultProvider);
    try {
      final plan = await folderPlanInBackground(vault.root, vault.indexPath);
      if (mounted) setState(() => _plan = plan);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '제안을 만들지 못했습니다: $e');
    }
  }

  Future<void> _run(List<FolderMove> moves) async {
    final isOk = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog.alert(
        title: Text('노트 ${moves.length}개를 옮길까요?'),
        description: const Text(
          '지식 폴더의 파일을 옮기고 이름을 바꿉니다. 번호·제목·[[링크]]는 그대로입니다. '
          '되돌리기 묶음 하나로 실행해 설정 > 되돌리기·휴지통에서 통째로 되돌릴 수 있습니다. '
          '옮기기 전의 되돌리기 기록은 "경로 바뀜"이 되어, 이 옮기기를 되돌리기 전에는 되돌릴 수 없습니다.',
        ),
        actions: [
          ShadButton.outline(child: const Text('취소'), onPressed: () => Navigator.of(context).pop(false)),
          ShadButton(child: const Text('옮기기'), onPressed: () => Navigator.of(context).pop(true)),
        ],
      ),
    );
    if (isOk != true || !mounted) return;
    final vault = ref.read(vaultProvider);
    final revision = ref.read(vaultRevisionProvider.notifier);
    // 창이 닫혀도 결과를 알리도록 앱의 알림 자리를 먼저 잡아 둔다
    final toaster = ShadToaster.maybeOf(context);
    final batch = newBatchId();
    setState(() {
      _isRunning = true;
      _isStopping = false;
      _done = 0;
      _total = moves.length;
      _errors.clear();
      _result = null;
    });
    final outcome = await runFolderTidy(
      moves,
      chunk: _chunk,
      moveChunk: (chunk, {required syncAfter}) =>
          moveNotesInBackground(vault.root, vault.indexPath, chunk, batch: batch, syncAfter: syncAfter),
      isStopping: () => _isStopping,
      onChunk: (done, errors) {
        if (mounted) {
          setState(() {
            _done = done;
            _errors.addAll(errors);
          });
        }
      },
    );
    revision.bump();
    final stopped = outcome.isStopped ? ' (멈춤: ${moves.length - outcome.done}개는 그대로)' : '';
    final message = outcome.failure != null
        ? '옮기다 멈췄습니다: ${outcome.failure} — 옮긴 ${outcome.moved}개는 묶음 $batch로 되돌릴 수 있습니다.'
        : '옮김 ${outcome.moved}개, 못 옮김 ${outcome.errors.length}개$stopped · 되돌리기 묶음 $batch';
    if (!mounted) {
      final description = Text(message);
      toaster?.show(
        outcome.failure != null || outcome.errors.isNotEmpty
            ? ShadToast.destructive(title: const Text('폴더 정리'), description: description)
            : ShadToast(title: const Text('폴더 정리'), description: description),
      );
      return;
    }
    setState(() {
      _result = message;
      _isRunning = false;
    });
    if (outcome.done == moves.length) await _load(); // 남은 노트로 목록을 새로
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final plan = _plan;
    return ShadDialog(
      title: const Text('폴더 정리'),
      description: const Text(
        '노트를 구역(프로젝트·개발 지식·조사·참고·공부·생활·기기) 아래 주제로 옮기고 파일 이름을 짧게 바꿉니다. '
        '제안은 추정입니다. 자리를 고친 뒤 승인하세요.',
      ),
      constraints: const BoxConstraints(maxWidth: 980),
      actions: [
        if (_isRunning)
          ShadButton.outline(
            enabled: !_isStopping,
            onPressed: () => setState(() => _isStopping = true),
            child: Text(_isStopping ? '멈추는 중…' : '멈추기'),
          ),
        ShadButton.outline(
          enabled: !_isRunning,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
      child: SizedBox(
        height: 560,
        child: _error != null
            ? Text(_error!, style: theme.textTheme.small)
            : plan == null
            ? const Center(child: Text('제안을 만드는 중…'))
            : FolderTidyView(
                proposals: plan.proposals,
                oversized: plan.oversized,
                isRunning: _isRunning,
                done: _done,
                total: _total,
                result: _result,
                errors: _errors,
                onRun: _run,
              ),
      ),
    );
  }
}

/// [폴더 정리]의 목록·선택·자리 고치기 (화면만, 파일은 [onRun]이 옮긴다). 시험에서 바로 그린다.
class FolderTidyView extends StatefulWidget {
  const FolderTidyView({
    super.key,
    required this.proposals,
    required this.onRun,
    this.oversized = const {},
    this.isRunning = false,
    this.done = 0,
    this.total = 0,
    this.result,
    this.errors = const [],
  });

  final List<FolderProposal> proposals;

  /// 노트가 30개 넘는 주제 → 노트 수. 나누자고 제안한다.
  final Map<String, int> oversized;
  final void Function(List<FolderMove> moves) onRun;
  final bool isRunning;
  final int done;
  final int total;
  final String? result;
  final List<MoveError> errors;

  @override
  State<FolderTidyView> createState() => _FolderTidyViewState();
}

class _FolderTidyViewState extends State<FolderTidyView> {
  final _off = <String>{};
  final _topics = <String, String>{};
  final _names = <String, String>{};

  @override
  void didUpdateWidget(FolderTidyView old) {
    super.didUpdateWidget(old);
    if (!identical(old.proposals, widget.proposals)) {
      final ids = {for (final p in widget.proposals) p.id};
      _off.removeWhere((id) => !ids.contains(id));
    }
  }

  String _topicOf(FolderProposal p) => _topics[p.id] ?? p.topic;

  String _nameOf(FolderProposal p) => _names[p.id] ?? p.name;

  /// 지금 자리(예전 주제) → 그 노트들. 화면에서 주제째 자리를 바꾸기 쉽게 묶는다.
  Map<String, List<FolderProposal>> get _groups {
    final out = <String, List<FolderProposal>>{};
    for (final p in widget.proposals) {
      out.putIfAbsent(_currentTopic(p), () => []).add(p);
    }
    return out;
  }

  static String _currentTopic(FolderProposal p) {
    final parts = p.from.split('/');
    return parts.length >= 3 ? parts[1] : '미분류';
  }

  /// 자리 고치기 창. 주제째(ids 여럿) 또는 한 노트(이름도).
  Future<void> _edit(List<FolderProposal> rows, {required bool withName}) async {
    final topic = TextEditingController(text: _topicOf(rows.first));
    final name = TextEditingController(text: withName ? _nameOf(rows.first) : '');
    String? error;
    final isOk = await showShadDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => ShadDialog(
          title: Text(withName ? '자리와 이름 바꾸기' : '이 주제 노트 ${rows.length}개의 자리 바꾸기'),
          description: Text('구역/주제로 적습니다. 구역: ${noteZones.join(', ')}'),
          actions: [
            ShadButton.outline(child: const Text('취소'), onPressed: () => Navigator.of(context).pop(false)),
            ShadButton(
              child: const Text('바꾸기'),
              onPressed: () {
                try {
                  // 구역 없이 주제 이름만은 받지 않는다: 화면에서는 구역까지 정하게 (기존 주제 목록을 넘기지 않음)
                  resolveTopicPath(topic.text, (_) => const []);
                  if (withName && name.text.trim().isEmpty) throw const NoteStoreException('파일 이름이 비었습니다.');
                  Navigator.of(context).pop(true);
                } on NoteStoreException catch (e) {
                  setLocal(() => error = e.message.split('\n').take(2).join(' '));
                }
              },
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ShadInput(controller: topic, autofocus: true, placeholder: const Text('예: 개발 지식/Flutter')),
              if (withName) ...[
                const SizedBox(height: 8),
                ShadInput(controller: name, placeholder: const Text('파일 이름 (20자 안팎)')),
              ],
              if (error != null) ...[const SizedBox(height: 8), Text(error!, style: TextStyle(color: AppColors.of(context).danger))],
            ],
          ),
        ),
      ),
    );
    if (isOk == true) {
      final resolved = resolveTopicPath(topic.text, (_) => const []);
      setState(() {
        for (final row in rows) {
          _topics[row.id] = resolved;
        }
        if (withName) _names[rows.first.id] = name.text.trim();
      });
    }
    topic.dispose();
    name.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final selected = [for (final p in widget.proposals) if (!_off.contains(p.id)) p];
    final groups = _groups;
    final rows = <Widget>[];
    for (final MapEntry(key: current, value: items) in groups.entries) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Row(
            children: [
              Expanded(child: Text('$current · ${items.length}개', style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600))),
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                enabled: !widget.isRunning,
                onPressed: () => _edit(items, withName: false),
                child: const Text('이 주제 자리 바꾸기'),
              ),
            ],
          ),
        ),
      );
      for (final p in items) {
        rows.add(
          _Row(
            key: ValueKey(p.id),
            proposal: p,
            topic: _topicOf(p),
            name: _nameOf(p),
            isOn: !_off.contains(p.id),
            isEnabled: !widget.isRunning,
            onToggle: () => setState(() => _off.contains(p.id) ? _off.remove(p.id) : _off.add(p.id)),
            onEdit: () => _edit([p], withName: true),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final MapEntry(key: topic, value: count) in widget.oversized.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '주제 $topic에 노트가 $count개입니다 ($topicSplitLimit개 넘음). 둘 이상의 주제로 나누기를 권합니다.',
              style: TextStyle(color: colors.warning, fontSize: 12),
            ),
          ),
        if (widget.proposals.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('구역 밖 노트가 없습니다. 옮길 것이 없습니다.', style: theme.textTheme.muted),
          )
        else ...[
          Row(
            children: [
              Expanded(child: Text('노트 · 지금 자리 → 제안 자리 / 제안 이름', style: theme.textTheme.muted)),
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                enabled: !widget.isRunning,
                onPressed: () => setState(() => _off.isEmpty ? _off.addAll(widget.proposals.map((p) => p.id)) : _off.clear()),
                child: Text(_off.isEmpty ? '모두 해제' : '모두 선택'),
              ),
            ],
          ),
          Expanded(child: ListView(children: rows)),
        ],
        if (widget.isRunning || widget.total > 0) ...[
          const SizedBox(height: 8),
          ShadProgress(value: widget.total == 0 ? 0 : widget.done / widget.total),
          const SizedBox(height: 4),
          Text(widget.isRunning ? '${widget.done}/${widget.total} 옮기는 중…' : '${widget.done}/${widget.total} 끝', style: theme.textTheme.muted),
        ],
        if (widget.result != null) Text(widget.result!, style: theme.textTheme.small),
        for (final e in widget.errors.take(20)) Text('· ${e.id}: ${e.message}', style: TextStyle(color: colors.danger, fontSize: 12)),
        if (widget.errors.length > 20) Text('그 밖 ${widget.errors.length - 20}개', style: theme.textTheme.muted),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: ShadButton(
            enabled: !widget.isRunning && selected.isNotEmpty,
            onPressed: () => widget.onRun([for (final p in selected) p.toMove(topic: _topicOf(p), name: _nameOf(p))]),
            child: Text('고른 ${selected.length}개 옮기기'),
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.proposal,
    required this.topic,
    required this.name,
    required this.isOn,
    required this.isEnabled,
    required this.onToggle,
    required this.onEdit,
  });

  final FolderProposal proposal;
  final String topic;
  final String name;
  final bool isOn;
  final bool isEnabled;
  final VoidCallback onToggle;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final small = TextStyle(fontSize: 12, color: colors.text);
    final faint = TextStyle(fontSize: 11, color: colors.textFaint);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          ShadCheckbox(value: isOn, enabled: isEnabled, onChanged: (_) => onToggle()),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(proposal.title, style: small, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(proposal.reason, style: faint, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(proposal.from, style: faint, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: Text('→ $topic / $name.md', style: small, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          ShadButton.ghost(size: ShadButtonSize.sm, enabled: isEnabled, onPressed: onEdit, child: const Text('바꾸기')),
        ],
      ),
    );
  }
}
