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
    final batch = newBatchId();
    setState(() {
      _isRunning = true;
      _isStopping = false;
      _done = 0;
      _total = moves.length;
      _errors.clear();
      _result = null;
    });
    var moved = 0;
    try {
      for (var start = 0; start < moves.length; start += _chunk) {
        final end = (start + _chunk).clamp(0, moves.length);
        final isLast = end == moves.length;
        final result = await moveNotesInBackground(
          vault.root,
          vault.indexPath,
          moves.sublist(start, end),
          batch: batch,
          syncAfter: isLast,
        );
        moved += result.moved.length;
        if (!mounted) return;
        setState(() {
          _done = end;
          _errors.addAll(result.errors);
        });
        if (isLast) break;
        if (_isStopping) {
          // 멈추면 여기까지 옮긴 것으로 색인·자동 목차만 맞춘다 (빈 목록 = 맞추기만)
          await moveNotesInBackground(vault.root, vault.indexPath, const [], batch: batch, syncAfter: true);
          break;
        }
      }
      final stopped = _done < _total ? ' (멈춤: ${_total - _done}개는 그대로)' : '';
      setState(() => _result = '옮김 $moved개, 못 옮김 ${_errors.length}개$stopped · 되돌리기 묶음 $batch');
    } on Object catch (e) {
      if (mounted) setState(() => _result = '옮기다 멈췄습니다: $e — 옮긴 $moved개는 묶음 $batch로 되돌릴 수 있습니다.');
    } finally {
      revision.bump();
      if (mounted) setState(() => _isRunning = false);
    }
    if (mounted && _done == _total) await _load(); // 남은 노트로 목록을 새로
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
