#!/bin/bash
# 기획안 Word·PDF를 다시 만든다. 내용 수정은 content.js에서 한다.
# 사용법: bash docs/기획안_원본/make.sh
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/../.." && pwd)"
NAME="기말프로젝트_기획안_김민상"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
file_url() { node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$1"; }

cd "$SRC"
[ -d node_modules ] || npm install --silent
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$TMP/chrome" \
  --force-device-scale-factor=2 --window-size=1600,760 \
  --screenshot="$SRC/diagram.png" "$(file_url "$SRC/diagram.html")" >/dev/null 2>&1
node build.js "$ROOT" "$NAME"
"$CHROME" --headless=new --disable-gpu --user-data-dir="$TMP/chrome" --no-pdf-header-footer \
  --print-to-pdf="$ROOT/$NAME.pdf" "$(file_url "$SRC/$NAME.html")" >/dev/null 2>&1
echo "완료: $ROOT/$NAME.docx, $ROOT/$NAME.pdf"
