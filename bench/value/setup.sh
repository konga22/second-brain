#!/bin/bash
# 사용가치 비교 시험 준비 (docs/사용가치분석.md). 실제 지식 폴더는 읽기만 하고 사본으로 시험한다.
#   bash bench/value/setup.sh <작업 폴더> [지식 폴더=~/SecondBrain]
# 만드는 것: vault(사본, D용) · notes(md 폴더, B용) · wA~wD(조건별 작업 폴더) · novault(빈 폴더) · cfg_on.json
set -euo pipefail
OUT="${1:?작업 폴더를 주세요}"; SRC="${2:-$HOME/SecondBrain}"
[ -d "$SRC/wiki" ] || { echo "지식 폴더가 아님: $SRC" >&2; exit 1; }
mkdir -p "$OUT"/{wA,wB,wC,wD,novault,notes}
rsync -a "$SRC/" "$OUT/vault/"
rsync -a "$SRC/wiki/" "$OUT/notes/"
rsync -a "$SRC/lessons/" "$OUT/notes/작업규칙_lessons/"
find "$OUT/notes" -name index.md -delete
cat > "$OUT/cfg_on.json" <<'J'
{"onboardingOff": false, "autoCaptureOff": false, "autoTidy": false, "uiScale": 1.0}
J
# B: 메모 폴더 + "거기서 찾아라" 한 줄 (Obsidian 폴더 + AI가 직접 grep 하는 방식)
cat > "$OUT/wB/CLAUDE.md" <<M
# 내 메모

내 개인 메모(지난 결정·설정·문제 해결·작업 규칙)는 \`$OUT/notes\` 폴더에 md 파일로 있다.
지난번에 정한 것·전에 했던 방법을 물으면 추측하지 말고 먼저 그 폴더에서 찾아 답한다. 작업 규칙은 \`$OUT/notes/작업규칙_lessons\`에 있다.
M
# C: 같은 노트 전부를 CLAUDE.md에 (늘 문맥에 들어감)
{
  echo "# 내 메모 전체 (지난 결정·설정·문제 해결·작업 규칙)"; echo
  (cd "$OUT/notes" && find . -name '*.md' | LC_ALL=C sort) | while IFS= read -r f; do
    echo "## 파일: ${f#./}"; cat "$OUT/notes/$f"; echo
  done
} > "$OUT/wC/CLAUDE.md"
echo "준비 끝: $OUT (노트 $(find "$OUT/notes" -name '*.md' | wc -l | tr -d ' ')개, C의 CLAUDE.md $(wc -c < "$OUT/wC/CLAUDE.md" | tr -d ' ')바이트)"
