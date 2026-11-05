#!/bin/bash
# 주간 보고 Word·PDF를 만든다. 내용은 원본/<회차>.js에서 고친다.
# 사용법: bash docs/주간보고/make.sh 00_기점
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
GEN="$DIR/../기획안_원본"
ID="$1"
SRC="$DIR/원본/$ID.js"
[ -n "$ID" ] && [ -f "$SRC" ] || { echo "사용법: bash docs/주간보고/make.sh <회차> (원본/<회차>.js가 있어야 한다)"; exit 1; }
NAME="주간보고_${ID}_김민상"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
file_url() { node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$1"; }

cd "$GEN"
[ -d node_modules ] || npm install --silent
node build.js "$DIR" "$NAME" "$SRC"
"$CHROME" --headless=new --disable-gpu --user-data-dir="$TMP/chrome" --no-pdf-header-footer \
  --print-to-pdf="$DIR/$NAME.pdf" "$(file_url "$DIR/원본/$NAME.html")" >/dev/null 2>&1
echo "완료: $DIR/$NAME.docx, $DIR/$NAME.pdf"
