import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../security/secret_mask.dart';
import 'claude_sessions.dart';

/// 압축 뒤 되살리기 (설계서_프롬프트이후 11/13 추가: 선호 → 실수 노트 / 압축 훅).
///
/// Claude Code가 대화를 압축하면 사용자가 한 지시·금지가 요약 속에서 뭉개진다. 압축 직후 SessionStart(source=compact)에서
/// 세션 기록 끝의 사용자 말 원문을 다시 넣는다. "지시처럼 보이는가"로 고르지 않는다 — 분류하지 않기로 했다(틀리게 거르면 그
/// 지시가 사라진다). 기록은 수십 MB라 끝에서부터 조각으로만 읽는다.
class CompactRecall {
  /// 다시 넣는 사용자 말 원문 합계 최대 글자 수 (11/13 압축 훅). 2,000자는 실제 기록에서 끝에서 2,239자 앞의 지시를
  /// 놓쳤다. 한 세션에 사람이 친 말 전체가 약 5,500자라 4,000자면 대부분의 최근 지시가 들어간다.
  static const maxChars = 4000;

  /// 끝에서부터 읽는 조각 크기와 최대 읽는 양. 실제 기록(60MB)은 도구 출력 줄이 커서 사용자 말이 드문드문 있다.
  /// [maxScanBytes]를 넘게 거슬러 가야 하면 그 앞 말은 이미 오래돼 넣지 않는다 (훅 제한 시간 안에 끝내는 것이 먼저).
  static const chunkBytes = 1024 * 1024;
  // 8MB로는 긴 세션(압축 6번, 기록 61MB)에서 사용자 말 2,335자만 닿아 11MB 앞의 핵심 지시가 빠졌다(11/13 실측). 압축 직후 한 번만 돌아 16MB(약 0.12초)도 괜찮다.
  static const maxScanBytes = 16 * 1024 * 1024;

  /// [transcriptPath]의 사용자 말 원문을 오래된 것부터. 최근 것부터 [maxChars]까지 담고 넘치면 거기서 멈춘다
  /// (가장 최근 말 하나가 넘치면 앞부분만 잘라 담는다). 비밀값은 가린다. [drop]이 참인 말은 뺀다(실수 노트와 같은 말).
  ///
  /// [projectsDir](`~/.claude/projects`) 안의 일반 `.jsonl` 파일이 아니면 읽지 않고 null — 훅 입력은 바깥에서 오므로
  /// 다른 파일을 읽게 하지 않는다. 읽다 실패해도 null (훅은 이것 없이 나머지 안내를 낸다).
  static List<String>? recentUserMessages(
    String transcriptPath, {
    required String projectsDir,
    int maxChars = CompactRecall.maxChars,
    bool Function(String text)? drop,
  }) {
    try {
      if (!_isAllowed(transcriptPath, projectsDir)) return null;
      final newestFirst = <String>[];
      var used = 0;
      // 한 줄씩 받아 담을지 정한다. 더 담을 수 없으면 false를 돌려 읽기를 멈춘다.
      bool take(Uint8List line) {
        final text = _userTextOf(line);
        if (text == null || (drop != null && drop(text))) return true;
        final length = text.runes.length;
        if (used + length <= maxChars) {
          newestFirst.add(text);
          used += length;
          return used < maxChars;
        }
        if (newestFirst.isEmpty) newestFirst.add('${String.fromCharCodes(text.runes.take(maxChars - 1))}…');
        return false;
      }

      _readLinesBackward(transcriptPath, take);
      return newestFirst.reversed.toList();
    } on Object {
      return null;
    }
  }

  static bool _isAllowed(String path, String projectsDir) {
    if (path.isEmpty || p.extension(path) != '.jsonl') return false;
    // 링크는 따라가지 않는다: 링크 자체가 파일이 아니면 거절한다.
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) return false;
    final root = Directory(projectsDir);
    if (!root.existsSync()) return false;
    return p.isWithin(root.resolveSymbolicLinksSync(), File(path).resolveSymbolicLinksSync());
  }

  /// 파일 끝에서부터 줄을 하나씩 [onLine]에 넘긴다. [onLine]이 false를 돌려주거나 [maxScanBytes]를 읽으면 멈춘다.
  static void _readLinesBackward(String path, bool Function(Uint8List line) onLine) {
    final file = File(path).openSync();
    try {
      var position = file.lengthSync();
      var scanned = 0;
      var carry = Uint8List(0); // 조각 앞쪽에서 아직 끝나지 않은 줄
      while (position > 0 && scanned < maxScanBytes) {
        final size = position < chunkBytes ? position : chunkBytes;
        position -= size;
        file.setPositionSync(position);
        final chunk = file.readSync(size);
        scanned += size;
        final buffer = carry.isEmpty ? chunk : (BytesBuilder(copy: false)..add(chunk)..add(carry)).takeBytes();
        var end = buffer.length;
        for (var i = buffer.length - 1; i >= 0; i--) {
          if (buffer[i] != 0x0a) continue;
          if (i + 1 < end && !onLine(Uint8List.sublistView(buffer, i + 1, end))) return;
          end = i;
        }
        carry = Uint8List.fromList(Uint8List.sublistView(buffer, 0, end));
      }
      if (position == 0 && carry.isNotEmpty) onLine(carry);
    } finally {
      file.closeSync();
    }
  }

  /// 사람이 친 말이 아닌 사용자 줄을 거르는 글자: 작업 알림, 다른 세션·하위 에이전트 보고 (훅 `_systemInput`과 같다).
  static final _systemText = RegExp(r'<task-notification>|\[SYSTEM NOTIFICATION|\[Subagent hand-back\]|<agent-message ');

  static String? _userTextOf(Uint8List bytes) {
    final line = utf8.decode(bytes, allowMalformed: true);
    // 사용자 줄만, 도구 결과는 풀지 않는다 (큰 줄을 JSON으로 풀지 않게)
    if (!line.contains('"type":"user"') || line.contains('"toolUseResult"')) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    // Claude Code 2.1.x는 사람이 친 말에 origin.kind=human을 단다. origin 없이 promptSource만 있는 줄은 앱이 넣은 말이다
    // (실제 기록: "I hit my usage limit … Please continue", 세션 알림만 든 줄).
    if (decoded['origin'] == null && decoded['promptSource'] != null) return null;
    final text = ClaudeSessions.humanUserText(decoded);
    if (text == null || _systemText.hasMatch(text)) return null;
    return maskSecrets(text);
  }
}
