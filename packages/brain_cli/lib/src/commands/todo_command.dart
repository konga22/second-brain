import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:brain_core/brain_core.dart';

import '../brain_context.dart';

/// `brain todo [list|add|suggest]`: 할 일 (설계서 3절 `/todos`).
/// AI는 대화·노트에서 나온 할 일을 `suggest`로 추천 칸에 넣고, 사용자가 앱에서 받거나 버린다.
class TodoCommand extends Command<int> {
  TodoCommand(this.context) {
    argParser.addOption('source', help: '근거 노트 id (suggest)');
  }

  final BrainContext context;

  @override
  String get name => 'todo';

  @override
  String get description =>
      '할 일. brain todo (목록) · brain todo add <내용> · brain todo suggest <내용> --source n_0012';

  @override
  int run() {
    final rest = argResults!.rest;
    final store = TodoStore(context.vault, context.index);
    final action = rest.isEmpty ? 'list' : rest.first;
    final text = rest.skip(1).join(' ').trim();
    switch (action) {
      case 'add':
        if (text.isEmpty) usageException('할 일 내용을 주세요.');
        store.add(text);
        stdout.writeln('할 일 추가함: $text');
      case 'suggest':
        if (text.isEmpty) usageException('추천할 할 일 내용을 주세요.');
        final added = store.suggest(text, source: argResults!['source'] as String?);
        stdout.writeln(added ? '추천 칸에 넣음 (앱 할 일에서 확인): $text' : '이미 있는 할 일이라 넣지 않음');
      case 'list':
        final todos = store.list().where((t) => !t.isDone).toList();
        final suggestions = store.suggestions();
        if (todos.isEmpty && suggestions.isEmpty) stdout.writeln('할 일 없음');
        for (final t in todos) {
          stdout.writeln('- ${t.text}');
        }
        for (final t in suggestions) {
          stdout.writeln('- (추천) ${t.text}');
        }
      default:
        // `brain todo done 보고서`처럼 없는 동작이 목록을 보여 주고 성공(0)으로 끝나 AI가 끝낸 줄 알았다 (11/11 K-37).
        // 할 일을 끝내는 것은 앱의 체크 상자에서 한다.
        usageException('모르는 동작: $action (list·add·suggest만 있습니다. 끝낸 표시는 앱의 할 일 화면에서 합니다)');
    }
    return 0;
  }
}
