import 'dart:convert';
import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 세션 기록 (11/11 독립 검토 K-35): 축약본이 세션과 함께 자라고, 세션 묶음을 되돌리면 다시 정리 대상이 된다.
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;
  late File transcript;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('session_record_');
    vault = Vault(p.join(temp.path, 'SecondBrain'))..ensure();
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
    final project = Directory(p.join(temp.path, 'projects', '-Users-me-app'))..createSync(recursive: true);
    transcript = File(p.join(project.path, 'feedbeef-0001.jsonl'));
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  void say(String text) => transcript.writeAsStringSync(
    '${jsonEncode({
      'type': 'user',
      'sessionId': 'feedbeef-0001',
      'cwd': '/Users/me/app',
      'timestamp': '2026-11-07T10:00:00.000Z',
      'message': {'role': 'user', 'content': text},
    })}\n',
    mode: FileMode.append,
  );

  ClaudeSession session() =>
      ClaudeSessions(projectsDir: p.join(temp.path, 'projects')).find('feedbeef', vault: vault)!;

  test('세션이 이어지면 축약본을 다시 쓴다 (뒤에 나온 노트의 근거가 남게)', () {
    say('로그는 14일만 보관하기로 했어');
    final rel = archiveSession(vault, ClaudeSessions(projectsDir: p.join(temp.path, 'projects')), session());
    final file = File(p.join(vault.root, rel));
    expect(file.readAsStringSync(), contains('14일만 보관'));
    final created = Note.parse(file.readAsStringSync(), fallbackId: '', fallbackTitle: '').created;
    say('배포는 금요일에 하지 않기로 했어');
    archiveSession(vault, ClaudeSessions(projectsDir: p.join(temp.path, 'projects')), session());
    final text = file.readAsStringSync();
    expect(text, contains('금요일에 하지 않기로'), reason: '예전에는 첫 저장 때 축약본만 남았다');
    expect(Note.parse(text, fallbackId: '', fallbackTitle: '').created, created);
  });

  test('세션 묶음을 되돌리면 세션이 다시 "저장 안 함"이 되고, 다음 저장도 다시 되돌릴 수 있다', () {
    final notes = NoteStore(vault, index);
    final registry = SessionRegistry(vault);
    final (first, _) = notes.add(title: '로그 보관 기간', summary: '14일', body: '14일만 보관', batch: 's_feedbeef');
    registry.mark('feedbeef-0001', SessionStatus.saved, notes: [first]);

    undoBatch(vault, 's_feedbeef');
    expect(registry.load()['feedbeef-0001'], SessionStatus.unsaved);
    index.sync();
    expect(index.byId(first), isNull);

    // 같은 세션을 다시 정리해 저장 → 같은 묶음 이름
    final (second, _) = notes.add(title: '배포 요일', summary: '금요일 안 함', body: '금요일 배포 금지', batch: 's_feedbeef');
    expect(() => undoBatch(vault, 's_feedbeef'), returnsNormally, reason: '예전에는 "이미 되돌렸습니다"');
    index.sync();
    expect(index.byId(second), isNull);
    expect(recentBatches(vault).where((b) => b.id.startsWith('s_feedbeef')), hasLength(2));
  });

  // 11/13 검토 (설계서_프롬프트이후 4.4): 앱의 화면 없는 정리에서 AI가 옛 노트만 brain write로 고치면 세션 표시가
  // 남지 않아, 자동 정리가 같은 세션을 다시 돌려 예산을 썼다. 정리가 끝났는데 표시가 없으면 앱이 닫는다.
  test('정리가 끝났는데 표시가 없는 세션만 "저장할 것 없음"으로 닫는다 (저장함·일부 저장은 그대로)', () {
    final registry = SessionRegistry(vault);
    registry.mark('saved-1', SessionStatus.saved, notes: ['n_0001']);
    registry.mark('partial-1', SessionStatus.partial);
    expect(registry.closeIfOpen('none-1'), isTrue);
    expect(registry.closeIfOpen('saved-1'), isFalse);
    expect(registry.closeIfOpen('partial-1'), isFalse, reason: '일부 저장은 다음 정리 때 이어 읽어야 한다');
    final statuses = registry.load();
    expect(statuses['none-1'], SessionStatus.skipped);
    expect(statuses['saved-1'], SessionStatus.saved);
    expect(statuses['partial-1'], SessionStatus.partial);
  });
}
