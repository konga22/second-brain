/// 한글 NFC 정규화 (설계서 4.1 한글 정규화).
///
/// macOS 파일 이름·일부 도구는 한글을 자모로 풀어(NFD) 저장한다. 같은 제목이
/// 다른 바이트가 되면 검색·링크 비교가 어긋나므로, 비교하기 전에 조합형으로 맞춘다.
///
/// Dart 기본 라이브러리에 정규화가 없어서 유니코드 표준의 한글 조합 규칙
/// (초성+중성 → LV, LV+종성 → LVT)만 직접 구현한다. 라틴 문자의 결합 부호
/// (e + ́ → é)는 바꾸지 않는다. 지식 폴더의 대부분이 한글이라 이 범위로 충분하다고 보고,
/// 필요하면 정규화 패키지로 바꾼다.
library;

const _sBase = 0xAC00;
const _lBase = 0x1100;
const _vBase = 0x1161;
const _tBase = 0x11A7;
const _lCount = 19;
const _vCount = 21;
const _tCount = 28;
const _nCount = _vCount * _tCount;
const _sCount = _lCount * _nCount;

/// 풀어 쓴 한글 자모를 완성형 음절로 합친다. 바꿀 것이 없으면 원래 문자열을 돌려준다.
String toNfc(String text) {
  if (!_hasJamo(text)) return text;
  final out = <int>[];
  for (final rune in text.runes) {
    if (out.isNotEmpty) {
      final last = out.last;
      final l = last - _lBase;
      if (l >= 0 && l < _lCount) {
        final v = rune - _vBase;
        if (v >= 0 && v < _vCount) {
          out[out.length - 1] = _sBase + (l * _vCount + v) * _tCount;
          continue;
        }
      }
      final s = last - _sBase;
      if (s >= 0 && s < _sCount && s % _tCount == 0) {
        final t = rune - _tBase;
        if (t > 0 && t < _tCount) {
          out[out.length - 1] = last + t;
          continue;
        }
      }
    }
    out.add(rune);
  }
  return String.fromCharCodes(out);
}

bool _hasJamo(String text) {
  for (final unit in text.codeUnits) {
    if (unit >= _lBase && unit <= 0x11FF) return true;
  }
  return false;
}
