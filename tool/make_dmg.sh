#!/bin/bash
# 설치 파일(.dmg)을 만든다. 정식 빌드(tool/release.sh) 뒤에 실행한다.
#
#   bash tool/release.sh
#   bash tool/make_dmg.sh        # → dist/SecondBrain-<버전>.dmg
#
# 안: 앱 + 응용 프로그램 폴더 바로가기. 파일 이름은 영문(내려받는 쪽 OS·브라우저와 상관없이 안 깨지게),
# 디스크 이름·앱 이름은 한글(NFC). Apple 개발자 서명·공증은 없다(ad-hoc) → 처음 열 때 사용자가
# 시스템 설정 → 개인정보 보호 및 보안 → [그래도 열기]를 한 번 눌러야 한다 (docs/설치안내.md).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
APP="build/macos/Build/Products/Release/secondbrain.app"
APP_NAME="$(python3 -c 'import unicodedata as u; print(u.normalize("NFC", "세컨드 브레인"))')"
VERSION="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' pubspec.yaml)"
OUT="dist/SecondBrain-$VERSION.dmg"

[ -d "$APP" ] || { echo "오류: 정식 빌드가 없습니다. 먼저 bash tool/release.sh" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "오류: 앱 서명이 깨져 있습니다. bash tool/release.sh 를 다시 실행하세요." >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f "$OUT"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"
hdiutil verify -quiet "$OUT"
echo "설치 파일 끝: $OUT ($(du -h "$OUT" | cut -f1)), sha256 $(shasum -a 256 "$OUT" | cut -c1-16)…"
