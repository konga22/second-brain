import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
  builder: (context) =>
      _NoteEditor(noteId: noteId, initialTitle: initialTitle),
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
  bool _isSaving = false;

  bool get _isNew => widget.noteId == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) {
      _title.text = widget.initialTitle ?? '';
      return;
    }
    final found = ref.read(noteStoreProvider).read(widget.noteId!);
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
  }

  @override
  void dispose() {
    for (final c in [_title, _summary, _tags, _aliases, _topic, _body]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _split(String text) =>
      [for (final t in text.split(',')) if (t.trim().isNotEmpty) t.trim()];

  void _onSave() {
    setState(() {
      _isSaving = true;
      _error = null;
    });
    final store = ref.read(noteStoreProvider);
    try {
      final String id;
      if (_isNew) {
        (id, _) = store.add(
          title: _title.text,
          summary: _summary.text,
          body: _body.text,
          tags: _split(_tags.text),
          aliases: _split(_aliases.text),
          topic: _topic.text.trim().isEmpty ? null : _topic.text.trim(),
          batch: newBatchId(),
        );
      } else {
        id = widget.noteId!;
        store.update(
          id,
          expectHash: _hash!,
          title: _title.text,
          summary: _summary.text,
          body: _body.text,
          tags: _split(_tags.text),
          aliases: _split(_aliases.text),
        );
      }
      bumpVault(ref);
      ref.read(selectedNoteProvider.notifier).select(id);
      Navigator.of(context).pop(id);
    } on NoteStoreException catch (e) {
      setState(() {
        _error = e.message;
        _isSaving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final summaryLength = _summary.text.runes.length;
    return ShadDialog(
      title: Text(_isNew ? '새 노트' : '노트 고치기'),
      description: Text(
        _isNew
            ? '제목이 파일 이름이 됩니다. 다른 노트는 [[제목]]으로 잇습니다.'
            : '제목을 바꾸면 파일 이름과 이 노트를 가리키는 [[링크]]도 함께 바뀝니다.',
      ),
      constraints: const BoxConstraints(maxWidth: 680),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        ShadButton(
          enabled: !_isSaving,
          onPressed: _onSave,
          child: Text(_isSaving ? '저장 중…' : '저장'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShadInput(controller: _title, placeholder: const Text('제목'), autofocus: _isNew),
          const SizedBox(height: 8),
          ShadInput(
            controller: _summary,
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
                  placeholder: const Text('태그 (쉼표로)'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ShadInput(
                  controller: _aliases,
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
        ],
      ),
    );
  }
}
