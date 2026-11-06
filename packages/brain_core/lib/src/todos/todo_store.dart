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
}

/// 할 일 체크리스트 `todos.md` (설계서 4.1·3절 `/todos`).
class TodoStore {
  TodoStore(this.vault, this.index);

  final Vault vault;
  final SearchIndex index;

  static final _item = RegExp(r'^\s*[-*] \[( |x|X)\] (.+)$');

  File get file => File(p.join(vault.root, 'todos.md'));

  List<Todo> list() {
    if (!file.existsSync()) return const [];
    final lines = file.readAsLinesSync();
    return [
      for (final (i, line) in lines.indexed)
        if (_item.firstMatch(line) case final m?)
          Todo(text: m.group(2)!.trim(), isDone: m.group(1) != ' ', line: i),
    ];
  }

  void add(String text, {String? batch}) {
    final clean = maskSecrets(text.trim().replaceAll('\n', ' '));
    if (clean.isEmpty) return;
    final current = file.existsSync() ? file.readAsStringSync() : '# 할 일\n\n';
    recordBeforeChange(vault, file.path, batch: batch);
    writeFileAtomic(
      file.path,
      '${current.endsWith('\n') ? current : '$current\n'}- [ ] $clean\n',
    );
    appendChangeLog(vault, 'todo-add', clean, batch: batch);
  }

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
  ) {
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
