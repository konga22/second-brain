import 'dart:io';

import '../text/nfc.dart';
import 'vault.dart';

/// 페르소나 질문 4문항의 답 — 지식 폴더의 `me.md` (설계서_프롬프트이후 5.2).
///
/// 사용자 정보를 AI 추측이 아니라 사용자가 직접 쓴 것으로 둔다. 앱 [연동] 다음 단계와 [설정]에서만 쓰고,
/// 자동 작업(목차·요약·AI)은 이 파일을 고치지 않는다. 나이·성별·건강·가족은 묻지 않는다.
/// 사람이 열어 고칠 수 있게 `## 절` 네 개짜리 md로 둔다. 모르는 절은 읽어 두었다가 그대로 다시 쓴다.
class Persona {
  const Persona({
    this.work = '',
    this.keeps = const [],
    this.answerStyle = '',
    this.forbidden = const [],
    this.extra = '',
  });

  /// 2번 "주로 남길 것" 보기. 5.1의 고정 구역 5개(프로젝트·개발 지식·조사·참고·공부·생활·기기)와 맞춘다.
  static const keepChoices = ['프로젝트 결정·구조', '개발 지식·해결법', '조사·참고 자료', '수업·공부', '생활·기기'];

  static const styleShort = '짧게 결론 먼저';
  static const styleDetailed = '자세히 단계별';

  static const _workTitle = '지금 하는 일';
  static const _keepsTitle = '주로 남길 것';
  static const _styleTitle = '답 방식';
  static const _forbiddenTitle = '저장하면 안 되는 것';

  /// 1. 지금 하는 일 한 줄.
  final String work;

  /// 2. 주로 남길 것 (여러 개).
  final List<String> keeps;

  /// 3. 답 방식: [styleShort]·[styleDetailed] (손으로 고친 다른 말도 그대로 둔다).
  final String answerStyle;

  /// 4. 절대 저장하면 안 되는 것. `brain add`·`brain write`·앱 저장이 막는다 ([ForbiddenTerms]).
  final List<String> forbidden;

  /// 사용자가 손으로 더한 절 (그대로 다시 쓴다).
  final String extra;

  bool get isEmpty => work.isEmpty && keeps.isEmpty && answerStyle.isEmpty && forbidden.isEmpty;

  /// 세션 시작 안내 한 줄: 1번과 3번만 (설계서_프롬프트이후 5.2 표). 둘 다 없으면 null (0자).
  /// 금지 목록은 넣지 않는다 — 명령이 막으므로 AI가 알 필요가 없고, 넣으면 그 말들이 AI 문맥에 늘 실린다.
  /// 바뀌는 값이 없어 `me.md`가 그대로면 세션마다 같은 글이다 (캐시, 설계서 5.2).
  String? get sessionLine {
    final parts = [
      if (_flat(work) case final w when w.isNotEmpty) '사용자: ${_clip(w, 60)}',
      if (_flat(answerStyle) case final s when s.isNotEmpty) '답 방식: ${_clip(s, 20)}',
    ];
    return parts.isEmpty ? null : '· ${parts.join(' · ')}';
  }

  /// `me.md`가 없으면 null. 읽지 못하면 [FileSystemException]·[FormatException]을 그대로 던진다
  /// (금지어를 못 읽은 채 저장을 허락하지 않게, 부르는 쪽이 정한다).
  static Persona? load(Vault vault) {
    final file = File(vault.mePath);
    if (!file.existsSync()) return null;
    return parse(file.readAsStringSync());
  }

  static Persona parse(String text) {
    final sections = <String, List<String>>{};
    final extra = StringBuffer();
    String? current;
    for (final line in text.replaceAll('\r\n', '\n').split('\n')) {
      if (line.startsWith('## ')) {
        current = line.substring(3).trim();
        if (!const [_workTitle, _keepsTitle, _styleTitle, _forbiddenTitle].contains(current)) {
          extra.writeln(line);
          current = '';
        }
        continue;
      }
      if (current == null) continue; // 머리 제목·안내문
      if (current.isEmpty) {
        extra.writeln(line);
      } else {
        sections.putIfAbsent(current, () => []).add(line);
      }
    }
    List<String> lines(String title) => [
      for (final l in sections[title] ?? const <String>[])
        if (l.trim().isNotEmpty) l.trim(),
    ];
    return Persona(
      work: lines(_workTitle).join(' '),
      keeps: _items(lines(_keepsTitle)),
      answerStyle: lines(_styleTitle).firstOrNull ?? '',
      forbidden: _items(lines(_forbiddenTitle)),
      extra: extra.toString().trim(),
    );
  }

  /// 입력 칸 글(쉼표나 줄로 나눔)을 항목으로. 앱 4번 칸이 쓴다.
  static List<String> splitItems(String text) => _items(text.split('\n'));

  /// `- 가`·`가, 나` 줄을 항목으로 (쉼표는 전각·가운뎃점 쉼표도).
  static List<String> _items(List<String> lines) => [
    for (final line in lines)
      for (final part in line.trim().replaceFirst(RegExp(r'^[-*]\s*'), '').split(RegExp('[,，、]')))
        if (part.trim().isNotEmpty) part.trim(),
  ];

  String toMarkdown() {
    String list(List<String> items) => items.map((i) => '- $i\n').join();
    final out = StringBuffer()
      ..writeln('# 나에 대해 (사용자가 쓴 것)')
      ..writeln()
      ..writeln('세컨드 브레인 [설정] > 나에 대해에서 고칩니다. 자동 작업은 이 파일을 고치지 않습니다.')
      ..writeln('"저장하면 안 되는 것"이 든 노트는 이 맥에서 저장을 막습니다 (서버로 보내지 않음).')
      ..writeln()
      ..writeln('## $_workTitle')
      ..write(work.trim().isEmpty ? '' : '${_flat(work)}\n')
      ..writeln()
      ..writeln('## $_keepsTitle')
      ..write(list(keeps))
      ..writeln()
      ..writeln('## $_styleTitle')
      ..write(answerStyle.trim().isEmpty ? '' : '${_flat(answerStyle)}\n')
      ..writeln()
      ..writeln('## $_forbiddenTitle')
      ..write(list(forbidden));
    if (extra.isNotEmpty) {
      out
        ..writeln()
        ..writeln(extra);
    }
    return out.toString();
  }

  /// 원자적으로 쓴다 (쓰다가 꺼져도 반쪽 파일이 남지 않게).
  void save(Vault vault) => writeFileAtomic(vault.mePath, toMarkdown());

  Persona copyWith({String? work, List<String>? keeps, String? answerStyle, List<String>? forbidden}) => Persona(
    work: work ?? this.work,
    keeps: keeps ?? this.keeps,
    answerStyle: answerStyle ?? this.answerStyle,
    forbidden: forbidden ?? this.forbidden,
    extra: extra,
  );

  @override
  bool operator ==(Object other) =>
      other is Persona &&
      other.work == work &&
      other.answerStyle == answerStyle &&
      other.extra == extra &&
      _sameList(other.keeps, keeps) &&
      _sameList(other.forbidden, forbidden);

  @override
  int get hashCode => Object.hash(work, answerStyle, extra, Object.hashAll(keeps), Object.hashAll(forbidden));

  @override
  String toString() => 'Persona(work: $work, keeps: $keeps, answerStyle: $answerStyle, forbidden: ${forbidden.length}개)';
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _flat(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

String _clip(String text, int max) {
  final runes = text.runes.toList();
  return runes.length <= max ? text : '${String.fromCharCodes(runes.take(max))}…';
}

/// 4번 "절대 저장하면 안 되는 것" 검사 (설계서_프롬프트이후 5.2). 기기에서만 하고 서버로 보내지 않는다.
///
/// - 2글자 이상만 본다(띄어쓰기 빼고): "돈" 같은 1글자는 흔한 글자라 거의 모든 노트가 막힌다.
/// - 대소문자, 자모로 풀어 쓴 한글(NFD, macOS 붙여넣기), 금지어 안 띄어쓰기("집 주소" ↔ "집주소")와 상관없이 찾는다.
/// - 글자 조각으로 찾는다: 한국어는 조사가 붙어("연봉을", "연봉협상") 단어 경계로는 놓친다. 대신 다른 말 속에
///   우연히 든 경우("수집 주소")도 막힌다 — 놓치는 것보다 낫다고 본다(사용자가 금지어를 고치면 된다).
class ForbiddenTerms {
  ForbiddenTerms(Iterable<String> raw) {
    final seen = <String>{};
    for (final term in raw) {
      final shown = _flat(toNfc(term));
      final key = shown.toLowerCase();
      if (key.replaceAll(' ', '').runes.length < 2 || !seen.add(key)) continue;
      _shown.add(shown);
      _patterns.add(RegExp(key.split(' ').map(RegExp.escape).join(r'\s*')));
    }
  }

  final _shown = <String>[];
  final _patterns = <RegExp>[];

  /// 검사하는 금지어 (소문자로 맞춘 것).
  List<String> get terms => [for (final s in _shown) s.toLowerCase()];

  bool get isEmpty => _shown.isEmpty;

  /// [text]에 든 첫 금지어 (사용자가 쓴 모양), 없으면 null.
  String? find(String text) {
    if (_shown.isEmpty || text.isEmpty) return null;
    final normalized = toNfc(text).toLowerCase();
    for (final (i, pattern) in _patterns.indexed) {
      if (pattern.hasMatch(normalized)) return _shown[i];
    }
    return null;
  }
}
