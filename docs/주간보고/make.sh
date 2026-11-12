#!/bin/bash
# 주간 보고 Word·PDF를 만든다. 내용은 원본/<회차>.js에서 고친다.
# 사용법: bash docs/주간보고/make.sh 00_기점
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
GEN="$DIR/../기획안_원본"
ID="$1"
SRC="$DIR/원본/$ID.js"
[ -n "$ID" ] && [ -f "$SRC" ] || { echo "사용법: bash docs/주간보고/make.sh <회차> (원본/<회차>.js가 있어야 한다)"; exit 1; }
# 파일 이름은 NFC(완성형)로 만든다. 자모로 나뉜 NFD 이름은 윈도우에서 "ㅈㅜㄱㅏㄴ…"으로 깨진다 (11/12 1주차 보고).
nfc() { python3 -c 'import sys,unicodedata as u; print(u.normalize("NFC", sys.argv[1]))' "$1"; }
# 디스크에 실제로 적힌 이름(디렉터리 목록)을 본다. APFS는 NFC·NFD를 같은 파일로 찾아 주므로 경로 문자열만으로는 모른다.
check_nfc() { python3 -c 'import sys,os,unicodedata as u
def ok(p):
    d,b=os.path.split(p); key=u.normalize("NFC",b)
    names=[n for n in os.listdir(d or ".") if u.normalize("NFC",n)==key]
    return bool(names) and all(u.is_normalized("NFC",n) for n in names)
bad=[p for p in sys.argv[1:] if not ok(p)]
sys.exit("파일 이름이 NFC가 아니거나 없음: "+", ".join(bad) if bad else 0)' "$@"; }
NAME="$(nfc "주간보고_${ID}_김민상")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
file_url() { node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$1"; }

cd "$GEN"
[ -d node_modules ] || npm install --silent
node build.js "$DIR" "$NAME" "$SRC"
"$CHROME" --headless=new --disable-gpu --user-data-dir="$TMP/chrome" --no-pdf-header-footer \
  --print-to-pdf="$DIR/$NAME.pdf" "$(file_url "$DIR/원본/$NAME.html")" >/dev/null 2>&1
check_nfc "$DIR/$NAME.docx" "$DIR/$NAME.pdf"
echo "완료: $DIR/$NAME.docx, $DIR/$NAME.pdf"
