#!/bin/bash
# 정식 빌드한 앱을 응용 프로그램 폴더에 설치한다 (Spotlight·Launchpad에서 "세컨드 브레인"으로 찾을 수 있게).
#
# 개발 중인 앱은 build/ 안에만 있어 검색에 나오지 않았고, USB의 디스크 이미지가 붙어 있어야 켤 수 있었다
# (11/11 사용자: "맥 앱에 세컨드 브레인 검색해도 안 나와"). 지식 폴더(~/SecondBrain)와 색인은 맥 안에 있으므로
# 설치한 앱은 USB 없이도 켜진다.
#
#   bash tool/release.sh       # 먼저 정식 빌드
#   bash tool/install_app.sh   # 응용 프로그램 폴더에 복사
#
# 새로 빌드할 때마다 다시 실행해야 설치한 앱이 최신이 된다. 켜져 있는 앱은 끄지 않는다 — 껐다 켜야 새 판으로 돈다.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$REPO/build/macos/Build/Products/Release/secondbrain.app"
BRAIN_IN_APP="Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/brain/bin/brain"

if [ ! -d "$SOURCE" ]; then
  echo "오류: 정식 빌드가 없습니다. 먼저 bash tool/release.sh 를 실행하세요." >&2
  exit 1
fi
# 옛 brain이 묶인 앱을 설치하지 않는다 (기능검토 K-22).
if [ "$(cat "$REPO/assets/brain/SOURCE_HASH" 2>/dev/null)" != "$(bash "$REPO/tool/brain_source_hash.sh")" ] ||
  ! cmp -s "$REPO/assets/brain/bin/brain" "$SOURCE/$BRAIN_IN_APP"; then
  echo "오류: 빌드한 앱 안의 brain이 지금 소스와 다릅니다. bash tool/release.sh 를 다시 실행하세요." >&2
  exit 1
fi

# 임시 이름으로 복사한 뒤 바꿔치기한다 (복사 도중 실패해도 기존 설치본이 남게).
rm -rf "/Applications/.세컨드 브레인.설치중.app"
ditto "$SOURCE" "/Applications/.세컨드 브레인.설치중.app"
rm -rf "/Applications/세컨드 브레인.app"
mv "/Applications/.세컨드 브레인.설치중.app" "/Applications/세컨드 브레인.app"

echo "설치 끝: /Applications/세컨드 브레인.app ($(du -sh "/Applications/세컨드 브레인.app" | cut -f1), 앱 안 brain $(stat -f '%Sm' -t '%m/%d %H:%M' "/Applications/세컨드 브레인.app/$BRAIN_IN_APP"))"
if ps -axo command | grep -q "[s]econdbrain.app/Contents/MacOS/secondbrain\|[세]컨드 브레인.app/Contents/MacOS/secondbrain"; then
  echo "알림: 세컨드 브레인이 켜져 있습니다. 껐다 켜야 새로 설치한 판으로 돕니다."
fi
