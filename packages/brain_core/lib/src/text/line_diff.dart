/// 줄 단위 비교 (설계서_프롬프트이후 4.3 [바뀐 내용 보기]). 노트는 길어야 몇백 줄이라 단순 LCS로 충분하다.
library;

enum DiffKind { same, added, removed }

class DiffLine {
  const DiffLine(this.kind, this.text);

  final DiffKind kind;
  final String text;
}

/// [before] → [after]의 줄 차이. 같은 줄은 [DiffKind.same], 빠진 줄은 removed, 새 줄은 added.
/// 아주 긴 노트(각 2,000줄 넘음)는 표가 커지므로 통째로 빠지고 생긴 것으로 보인다.
List<DiffLine> lineDiff(String before, String after) {
  final a = before.split('\n');
  final b = after.split('\n');
  if (a.length * b.length > 4000000) {
    return [
      for (final line in a) DiffLine(DiffKind.removed, line),
      for (final line in b) DiffLine(DiffKind.added, line),
    ];
  }
  // lcs[i][j] = a[i..]와 b[j..]의 가장 긴 공통 줄 수
  final lcs = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final out = <DiffLine>[];
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      out.add(DiffLine(DiffKind.same, a[i]));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.add(DiffLine(DiffKind.removed, a[i++]));
    } else {
      out.add(DiffLine(DiffKind.added, b[j++]));
    }
  }
  while (i < a.length) {
    out.add(DiffLine(DiffKind.removed, a[i++]));
  }
  while (j < b.length) {
    out.add(DiffLine(DiffKind.added, b[j++]));
  }
  return out;
}
