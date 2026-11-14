import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:brain_core/brain_core.dart';

/// 명령 하나가 쓰는 지식 폴더·색인. 색인은 필요할 때만 연다.
class BrainContext {
  BrainContext() : vault = Vault.resolve();

  final Vault vault;
  SearchIndex? _index;

  SearchIndex get index => _index ??= SearchIndex.open(vault);

  NoteStore get notes => NoteStore(vault, index);

  LessonStore get lessons => LessonStore(vault, index);

  ClaudeSessions get sessions => ClaudeSessions(cacheDb: index.db);

  SessionRegistry get registry => SessionRegistry(vault);

  void close() => _index?.close();
}

/// 표준 입력 전체. 터미널에서 직접 실행했으면 null.
Future<String?> readStdin() async {
  if (stdin.hasTerminal) return null;
  return stdin.transform(utf8.decoder).join();
}

/// `2026-11-05` → `11/05`
String shortDate(DateTime? time) {
  if (time == null) return '--/--';
  final t = time.toLocal();
  return '${t.month.toString().padLeft(2, '0')}/${t.day.toString().padLeft(2, '0')}';
}

String clip(String text, int max) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final runes = flat.runes.toList();
  return runes.length <= max
      ? flat
      : '${String.fromCharCodes(runes.take(max))}…';
}

/// `90d`, `12w`, `all`
Duration? parseSince(String value) {
  if (value == 'all') return null;
  final match = RegExp(r'^(\d+)([dw])$').firstMatch(value);
  if (match == null) {
    throw FormatException('--since는 90d, 12w, all 형식입니다: $value');
  }
  final n = int.parse(match.group(1)!);
  return Duration(days: match.group(2) == 'w' ? n * 7 : n);
}

/// AI에게 가는 데이터 덩어리의 시작·끝 표시에 넣는 값: 실행마다 다른 16진수 6자리. 안의 글(노트·대화)이 끝 표시를 미리 적어
/// 데이터 밖인 척하지 못하게 한다 (11/11 K-30, 보안 감사 11/14: 내용 해시는 미리 맞출 수 있었다).
String randomMark() {
  final random = Random.secure();
  return [for (var i = 0; i < 3; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}
