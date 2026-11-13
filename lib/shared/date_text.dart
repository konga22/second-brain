/// 날짜 표시 (설계서 3.0 v1.3.23): 화면 어디서나 같은 모양으로 연·월·일·시각을 보인다.
library;

String _two(int n) => n.toString().padLeft(2, '0');

/// `2026-11-09 18:21` (기기 시간대).
String stamp(DateTime t) {
  final l = t.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}';
}

/// `2026-11-09` — 시각이 없는 값(실수 노트의 마지막 적용일 등).
String dayStamp(DateTime t) {
  final l = t.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)}';
}

/// `2026년 11월 9일 (일)` — 타임라인 날짜 머리.
String dayHeading(DateTime t) {
  final l = t.toLocal();
  const week = ['월', '화', '수', '목', '금', '토', '일'];
  return '${l.year}년 ${l.month}월 ${l.day}일 (${week[l.weekday - 1]})';
}
