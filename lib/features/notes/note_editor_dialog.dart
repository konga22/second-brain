import 'package:brain_core/brain_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../core/background_tasks.dart';
import '../../core/brain_providers.dart';

/// 새 노트·노트 고치기 대화상자 (설계서 3절 `/notes` 작성·수정).
///
/// 고칠 때는 연 시점의 해시를 기억했다가 저장할 때 비교한다. 그사이 사용자 AI·Obsidian이
/// 고쳤으면 저장을 거절하고 충돌 사본을 남긴다 (설계서 4.2 동시 쓰기).
Future<String?> showNoteEditor(
  BuildContext context, {
  String? noteId,
  String? initialTitle,
}) => showShadDialog<String>(
  context: context,
  // 바깥을 누르거나 ESC 한 번에 닫혀 쓴 글이 사라지지 않게 (11/11 K-24). 닫기는 [취소]·ESC → 확인.
  barrierDismissible: false,
  builder: (context) => _NoteEditor(noteId: noteId, initialTitle: initialTitle),
);

class _NoteEditor extends ConsumerStatefulWidget {
  const _NoteEditor({this.noteId, this.initialTitle});

  final String? noteId;
  final String? initialTitle;

  @override
  ConsumerState<_NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends ConsumerState<_NoteEditor> {
  final _title = TextEditingController();
  final _summary = TextEditingController();
  final _tags = TextEditingController();
  final _aliases = TextEditingController();
  final _topic = TextEditingController();
  final _body = TextEditingController();
  String? _hash;
  String? _error;

  /// 저장하려는데 그사이 다른 곳에서 노트가 바뀌었다 → [덮어쓰기]·[최신 내용 불러오기] (11/11 K-34).
  bool _hasConflict = false;
  bool _isSaving = false;

  /// 고칠 노트를 백그라운드에서 읽는 중 (1만 개에서 약 80ms). 그동안 칸은 읽기 전용.
  bool _isLoading = false;

  /// 연 시점의 내용. 바뀐 것이 있으면 닫기 전에 묻는다.
  String _initial = '';

  String get _current => [
    _title,
    _summary,
    _tags,
    _aliases,
    _topic,
    _body,
  ].map((c) => c.text).join('\u0000');

  bool get _isDirty => _current != _initial;

  /// 바뀐 내용이 있으면 버릴지 묻고, 버려도 되면 닫는다.
  Future<void> _confirmClose() async {
    if (!_isDirty) {
      Navigator.of(context).pop();
      return;
    }
    final isDiscard = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog.alert(
        title: const Text('저장하지 않고 닫을까요?'),
        description: const Text('쓴 내용이 사라집니다.'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('계속 쓰기'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('버리고 닫기'),
          ),
        ],
      ),
    );
    if (isDiscard == true && mounted) Navigator.of(context).pop();
  }

  bool get _isNew => widget.noteId == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) {
      _title.text = widget.initialTitle ?? '';
      _initial = _current;
      return;
    }
    _isLoading = true;
    _load();
  }

  /// 파일에서 지금 내용을 읽어 칸을 채운다 (처음 열 때, 충돌 뒤 [최신 내용 불러오기]).
  /// 읽기 전에 색인을 맞추므로 백그라운드에서 한다 (11/11 검토 O-5).
  Future<void> _load() async {
    final vault = ref.read(vaultProvider);
    try {
      final found = await readNoteInBackground(vault.root, vault.indexPath, widget.noteId!);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        if (found == null) {
          _error = '노트를 찾지 못했습니다.';
          return;
        }
        final (doc, note, hash) = found;
        _hash = hash;
        _title.text = note.title;
        _summary.text = note.summary;
        _tags.text = note.tags.join(', ');
        _aliases.text = note.aliases.join(', ');
        _topic.text = doc.topic;
        _body.text = note.body.trim();
        _initial = _current;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = '노트를 읽지 못했습니다: $e';
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_title, _summary, _tags, _aliases, _topic, _body]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _split(String text) => [
    for (final t in text.split(','))
      if (t.trim().isNotEmpty) t.trim(),
  ];

  /// 저장은 백그라운드에서 한다: 쓰기 전·후 색인 맞추기와 자동 목차가 노트 1만 개에서 약 235ms라
  /// 화면 스레드에서 하면 그동안 앱이 멈췄다 (11/11 검토 O-5).
  Future<void> _onSave() async {
    if (_isSaving || _isLoading) return;
    setState(() {
      _isSaving = true;
      _error = null;
      _hasConflict = false;
    });
    final vault = ref.read(vaultProvider);
    // 저장 중 창이 닫혀도 폴더 번호는 올려야 목록·그래프가 맞는다 → 미리 잡아 둔다.
    final revision = ref.read(vaultRevisionProvider.notifier);
    final topic = _topic.text.trim();
    try {
      final id = await saveNoteInBackground(
        vault.root,
        vault.indexPath,
        id: _isNew ? null : widget.noteId,
        expectHash: _isNew ? null : _hash,
        title: _title.text,
        summary: _summary.text,
        body: _body.text,
        tags: _split(_tags.text),
        aliases: _split(_aliases.text),
        topic: _isNew && topic.isNotEmpty ? topic : null,
        batch: _isNew ? newBatchId() : null,
      );
      revision.bump();
      if (!mounted) return;
      ref.read(selectedNoteProvider.notifier).select(id);
      _initial = _current; // 저장했으니 닫을 때 묻지 않는다
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(id);
      });
    } on NoteConflictException catch (e) {
      // 사이드바의 충돌 사본 수가 바로 보이게
      revision.bump();
      if (!mounted) return;
      setState(() {
        _error = '${e.message}\n내 것으로 덮어쓰거나, 최신 내용을 불러와 다시 고칠 수 있습니다.';
        _hasConflict = true;
        _isSaving = false;
      });
    } on NoteStoreException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _isSaving = false;
      });
    } on Object catch (e) {
      // 색인 잠김·파일 오류 등: "저장 중…"에 멈추지 않고 알린다. 쓴 글은 대화상자에 그대로 남는다.
      if (!mounted) return;
      setState(() {
        _error = '저장하지 못했습니다: $e';
        _isSaving = false;
      });
    }
  }

  /// 충돌: 지금 파일의 해시로 다시 저장한다 (다른 곳에서 바꾼 내용은 되돌리기 묶음에 남는다).
  Future<void> _onOverwrite() async {
    final vault = ref.read(vaultProvider);
    final found = await readNoteInBackground(vault.root, vault.indexPath, widget.noteId!);
    if (!mounted) return;
    if (found == null) {
      setState(() => _error = '노트를 찾지 못했습니다 (그사이 지워졌을 수 있습니다).');
      return;
    }
    _hash = found.$3;
    await _onSave();
  }

  /// 충돌: 내가 고친 것은 충돌 사본에 있으므로 버리고 지금 파일 내용으로 다시 채운다.
  void _onReloadLatest() {
    setState(() {
      _error = null;
      _hasConflict = false;
      _isLoading = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final summaryLength = _summary.text.runes.length;
    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmClose();
      },
      // 바깥 클릭으로 닫히지 않게 하면(barrierDismissible: false) ESC도 기본으로는 아무 일도 하지 않는다.
      // ESC는 닫으려는 뜻이니 바뀐 내용이 있으면 버릴지 묻는다.
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _confirmClose,
        },
        child: ShadDialog(
          title: Text(_isNew ? '새 노트' : '노트 고치기'),
          description: Text(
            _isNew
                ? '제목이 파일 이름이 됩니다. 다른 노트는 [[제목]]으로 잇습니다.'
                : '제목을 바꾸면 파일 이름과 이 노트를 가리키는 [[링크]]도 함께 바뀝니다.',
          ),
          constraints: const BoxConstraints(maxWidth: 680),
          actions: [
            ShadButton.outline(
              onPressed: _confirmClose,
              child: const Text('취소'),
            ),
            ShadButton(
              enabled: !_isSaving && !_isLoading,
              onPressed: _onSave,
              child: Text(_isSaving ? '저장 중…' : (_isLoading ? '불러오는 중…' : '저장')),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ShadInput(
                controller: _title,
                readOnly: _isLoading,
                placeholder: const Text('제목'),
                autofocus: _isNew,
              ),
              const SizedBox(height: 8),
              ShadInput(
                controller: _summary,
                readOnly: _isLoading,
                placeholder: const Text('요약 한 줄 (60자 이내, 검색 결과에 보임)'),
                onChanged: (_) => setState(() {}),
                trailing: Text(
                  '$summaryLength/60',
                  style: theme.textTheme.muted.copyWith(
                    color: summaryLength > 60 ? const Color(0xffdc2626) : null,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ShadInput(
                      controller: _tags,
                      readOnly: _isLoading,
                      placeholder: const Text('태그 (쉼표로)'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ShadInput(
                      controller: _aliases,
                      readOnly: _isLoading,
                      placeholder: const Text('다른 표기 (예: Xcode, 엑스코드)'),
                    ),
                  ),
                  if (_isNew) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: ShadInput(
                        controller: _topic,
                        placeholder: const Text('주제 폴더 (비우면 첫 태그)'),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              ShadTextarea(
                controller: _body,
                readOnly: _isLoading,
                placeholder: const Text('본문 (마크다운). 다른 노트는 [[제목]]으로 잇는다.'),
                minHeight: 220,
                maxHeight: 420,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Color(0xffdc2626)),
                  ),
                ),
              if (_hasConflict)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      ShadButton.outline(
                        size: ShadButtonSize.sm,
                        onPressed: _onReloadLatest,
                        child: const Text('최신 내용 불러오기'),
                      ),
                      const SizedBox(width: 8),
                      ShadButton.destructive(
                        size: ShadButtonSize.sm,
                        onPressed: _onOverwrite,
                        child: const Text('내 것으로 덮어쓰기'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
