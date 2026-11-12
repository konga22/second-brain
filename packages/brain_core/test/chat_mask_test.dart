import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 경로 B(앱 안 AI 질문)로 보내기 전 가림의 순서·범위 (11/11 검토 S-6·K-31).
/// 저장할 때도 가리지만, 사용자가 편집기로 직접 고친 노트는 가려지지 않은 채 있을 수 있다.
void main() {
  late Directory temp;
  late Vault vault;
  late SearchIndex index;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('chat_mask_');
    vault = Vault(p.join(temp.path, 'vault'))..ensure();
    index = SearchIndex.open(vault, path: p.join(temp.path, 'index.db'));
  });

  tearDown(() {
    index.close();
    temp.deleteSync(recursive: true);
  });

  test('500자 경계에 걸친 키·제목·요약의 키는 보내는 글에 남지 않는다', () {
    const key = 'sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345';
    final (id, path) = NoteStore(vault, index).add(title: '결제 웹훅 설정', summary: '요약', body: '본문');
    // 사용자가 편집기로 직접 고친 것처럼 파일을 바꾼다 (저장 때 가림을 거치지 않음)
    final file = File(p.join(vault.root, path));
    final lead = '결제 웹훅 설정 메모. ' * 40; // 키가 500자 경계에 걸치게
    expect(lead.length, greaterThan(490));
    final padded = lead.substring(0, 490);
    file.writeAsStringSync(file.readAsStringSync()
        .replaceFirst('title: "결제 웹훅 설정"', 'title: "결제 웹훅 $key"')
        .replaceFirst('summary: "요약"', 'summary: "키 $key"')
        .replaceFirst('본문', '$padded$key 뒤 문장'));
    index.sync();

    final context = ChatContext.build(vault, index, '결제 웹훅');
    final note = context.notes.singleWhere((n) => n.id == id);
    final sent = '${note.title} ${note.summary} ${note.snippet}';
    for (var n = 8; n <= key.length; n++) {
      expect(sent, isNot(contains(key.substring(0, n))), reason: '키 앞 $n자');
    }
    expect(note.title, contains('[가림]'));
    expect(note.summary, contains('[가림]'));
    expect(note.snippet.runes.length, lessThanOrEqualTo(ChatContext.snippetChars));
    // 자른 뒤 가렸다면(고치기 전 방식) 앞 10자가 그대로 나간다
    final cutFirst = maskSecrets(String.fromCharCodes('$padded$key 뒤 문장'.runes.take(ChatContext.snippetChars)));
    expect(cutFirst, contains(key.substring(0, 10)), reason: '비교: 자르고 가리면 새어 나간다');
  });
}
