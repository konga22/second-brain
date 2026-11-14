import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/search_index.dart';
import '../log/change_log.dart';
import '../security/secret_mask.dart';
import '../vault/vault.dart';

/// 할 일 한 줄. `todos.md`의 `- [ ] 내용` 또는 노트 본문의 체크 상자.
class Todo {
  const Todo({
    required this.text,
    required this.isDone,
    required this.line,
    this.noteId,
    this.noteTitle,
  });

  final String text;
  final bool isDone;

  /// 파일 안 줄 번호 (0부터).
  final int line;

  /// 노트에서 가져온 할 일이면 그 노트.
  final String? noteId;
  final String? noteTitle;

  /// AI가 추천한 할 일인가 (`todos.md`의 "## 추천" 아래, 사용자 확인 전).
  bool get isSuggestion => noteTitle == '추천';
}

/// 할 일 체크리스트 `todos.md` (설계서 4.1·3절 `/todos`).
class TodoStore {
  TodoStore(this.vault, this.index);

  final Vault vault;
  final SearchIndex index;

  static final _item = RegExp(r'^\s*[-*] \[( |x|X)\] (.+)$');

  File get file => File(p.join(vault.root, 'todos.md'));

  static const suggestionHeader = '## 추천 (확인 전)';

  /// 확정된 할 일 (추천 칸 위쪽).
  List<Todo> list() => _items().where((t) => !t.isSuggestion).toList();

  /// AI가 추천한 할 일 (사용자가 받거나 버리기 전).
  List<Todo> suggestions() => _items().where((t) => t.isSuggestion).toList();

  List<Todo> _items() {
    if (!file.existsSync()) return const [];
    final lines = file.readAsLinesSync();
    var inSuggestions = false;
    final items = <Todo>[];
    for (final (i, line) in lines.indexed) {
      if (line.startsWith('## ')) inSuggestions = line.trim() == suggestionHeader;
      final m = _item.firstMatch(line);
      if (m == null) continue;
      final text = m.group(2)!.trim();
      final source = RegExp(r'\s*\(근거: ([^)]+)\)$').firstMatch(text);
      items.add(
        Todo(
          text: source == null ? text : text.substring(0, source.start),
          isDone: m.group(1) != ' ',
          line: i,
          noteId: source?.group(1),
          noteTitle: inSuggestions ? '추천' : null,
        ),
      );
    }
    return items;
  }

  /// AI 추천 할 일을 "## 추천 (확인 전)" 칸에 넣는다. 같은 내용이 있으면 넣지 않는다.
  ///
  /// 할 일 쓰기는 모두 지식 폴더 잠금 안에서 읽고 쓴다: AI가 한 메시지에서 `brain todo suggest`를 여러 개 부르면
  /// 서로의 줄을 덮어 "넣음"이라고 답한 추천이 사라졌다 (데이터 안전 감사 11/14, 3개 동시 20번 중 20번).
  bool suggest(String text, {String? source, String? batch}) => withVaultLock(vault, () {
    final clean = maskSecrets(text.trim().replaceAll('\n', ' '));
    if (clean.isEmpty) return false;
    if (_items().any((t) => t.text == clean)) return false;
    final current = file.existsSync() ? file.readAsStringSync() : '# 할 일\n\n';
    final body = current.endsWith('\n') ? current : '$current\n';
    final line = '- [ ] $clean${source == null ? '' : ' (근거: $source)'}\n';
    recordBeforeChange(vault, file.path, batch: batch);
    writeFileAtomic(
      file.path,
      body.contains(suggestionHeader)
          ? '$body$line'
          : '$body\n$suggestionHeader\n\n$line',
    );
    appendChangeLog(vault, 'todo-suggest', clean, batch: batch);
    return true;
  });

  /// 추천을 받아들인다: 추천 칸에서 빼고 확정 목록에 넣는다.
  void accept(Todo todo, {String? batch}) => withVaultLock(vault, () {
    remove(todo, batch: batch);
    final current = file.readAsStringSync();
    final i = current.indexOf(suggestionHeader);
    final line = '- [ ] ${todo.text}${todo.noteId == null ? '' : ' (근거: ${todo.noteId})'}\n';
    recordBeforeChange(vault, file.path, batch: batch);
    writeFileAtomic(
      file.path,
      i < 0 ? '$current$line' : '${current.substring(0, i)}$line\n${current.substring(i)}',
    );
    appendChangeLog(vault, 'todo-accept', todo.text, batch: batch);
  });

  void add(String text, {String? batch}) => withVaultLock(vault, () {
    final clean = maskSecrets(text.trim().replaceAll('\n', ' '));
    if (clean.isEmpty) return;
    final current = file.existsSync() ? file.readAsStringSync() : '# 할 일\n\n';
    final body = current.endsWith('\n') ? current : '$current\n';
    // 확정 할 일은 추천 칸 위에 넣는다.
    final i = body.indexOf(suggestionHeader);
    recordBeforeChange(vault, file.path, batch: batch);
    writeFileAtomic(
      file.path,
      i < 0 ? '$body- [ ] $clean\n' : '${body.substring(0, i)}- [ ] $clean\n\n${body.substring(i)}',
    );
    appendChangeLog(vault, 'todo-add', clean, batch: batch);
  });

  void toggle(Todo todo, {String? batch}) => _editLine(todo, (line) {
    final m = _item.firstMatch(line)!;
    return line.replaceFirst('[${m.group(1)}]', todo.isDone ? '[ ]' : '[x]');
  }, todo.isDone ? 'todo-undo' : 'todo-done', batch);

  void remove(Todo todo, {String? batch}) =>
      _editLine(todo, (_) => null, 'todo-remove', batch);

  void _editLine(
    Todo todo,
    String? Function(String line) edit,
    String action,
    String? batch,
  ) => withVaultLock(vault, () {
    final lines = file.readAsLinesSync();
    if (todo.line >= lines.length || !lines[todo.line].contains(todo.text)) {
      throw StateError('할 일 목록이 그사이 바뀌었습니다. 다시 불러오세요.');
    }
    final replaced = edit(lines[todo.line]);
    if (replaced == null) {
      lines.removeAt(todo.line);
    } else {
      lines[todo.line] = replaced;
    }
    recordBeforeChange(vault, file.path, batch: batch);
    writeFileAtomic(file.path, '${lines.join('\n')}\n');
    appendChangeLog(vault, action, todo.text, batch: batch);
  });

  static final _todoLike = RegExp(
    r'(남은 ?(것|일|작업)|다음 할 일|할 일|해야 ?(한다|함|할)|확인 필요|시험 필요|TODO|마감)',
    caseSensitive: false,
  );

  /// 노트에서 찾은 할 일 후보 (AI 없이): "남은 것·다음 할 일·확인 필요" 같은 줄.
  /// 이미 할 일·추천에 있는 것은 뺀다. 사용자가 [추천에 넣기]로 고른다.
  List<Todo> candidatesFromNotes({int limit = 20}) {
    final existing = {for (final t in _items()) t.text};
    final out = <Todo>[];
    for (final doc in index.notes()) {
      final f = File(p.join(vault.root, doc.path));
      if (!f.existsSync()) continue;
      for (final (i, raw) in f.readAsLinesSync().indexed) {
        if (raw.startsWith('---') || !_todoLike.hasMatch(raw)) continue;
        final line = raw.replaceAll(RegExp(r'^[\s#>*-]+|\*\*'), '').trim();
        if (line.runes.length < 6 || line.startsWith('id:') || existing.contains(line)) continue;
        final text = line.runes.length > 80 ? '${String.fromCharCodes(line.runes.take(79))}…' : line;
        out.add(Todo(text: text, isDone: false, line: i, noteId: doc.id, noteTitle: doc.title));
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  /// 노트 본문의 안 끝난 체크 상자 (노트에서 가져온 할 일). 노트를 고치지 않고 보여 주기만 한다.
  List<Todo> fromNotes({int limit = 50}) {
    final todos = <Todo>[];
    for (final doc in index.notes()) {
      final f = File(p.join(vault.root, doc.path));
      if (!f.existsSync()) continue;
      for (final (i, line) in f.readAsLinesSync().indexed) {
        final m = _item.firstMatch(line);
        if (m == null || m.group(1) != ' ') continue;
        todos.add(
          Todo(
            text: m.group(2)!.trim(),
            isDone: false,
            line: i,
            noteId: doc.id,
            noteTitle: doc.title,
          ),
        );
        if (todos.length >= limit) return todos;
      }
    }
    return todos;
  }
}
