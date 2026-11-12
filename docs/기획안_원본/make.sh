#!/bin/bash
# 기획안 Word·PDF를 다시 만든다. 내용 수정은 content.js에서 한다.
# 사용법: bash docs/기획안_원본/make.sh
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/../.." && pwd)"
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
NAME="$(nfc "기말프로젝트_기획안_김민상")"
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
check_nfc "$ROOT/$NAME.docx" "$ROOT/$NAME.pdf"
echo "완료: $ROOT/$NAME.docx, $ROOT/$NAME.pdf"
