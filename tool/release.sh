#!/bin/bash
# 정식 빌드. brain CLI를 먼저 다시 빌드해 앱 자산에 넣고, 앱을 빌드한 뒤 앱 안의 brain이 방금 빌드한 것인지 확인한다.
# flutter build만 돌리면 assets/brain이 옛 판인 채로 묶인다 (11/11: 앱에 11/08 판 brain이 들어 있어
# [연동]이 플러그인을 옛 판으로 내렸다, 기능검토 K-22, 설계서 v1.3.27).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

bash tool/build_brain.sh

if [ -f env/supabase.json ]; then
  flutter build macos --release --dart-define-from-file=env/supabase.json
else
  echo "알림: env/supabase.json이 없어 서버 주소 없이 빌드합니다 (로그인·AI 질문은 동작하지 않음)." >&2
  flutter build macos --release
fi

APP="build/macos/Build/Products/Release/secondbrain.app"
IN_APP="$APP/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/brain/bin/brain"
if ! cmp -s assets/brain/bin/brain "$IN_APP"; then
  echo "오류: 앱 안의 brain이 assets/brain과 다릅니다: $IN_APP" >&2
  exit 1
fi
if [ "$(cat assets/brain/SOURCE_HASH)" != "$(bash tool/brain_source_hash.sh)" ]; then
  echo "오류: assets/brain이 지금 소스로 빌드한 것이 아닙니다. 빌드 도중 소스가 바뀌었는지 확인하세요." >&2
  exit 1
fi
echo "정식 빌드 끝: $APP ($(du -sh "$APP" | cut -f1)), 앱 안 brain $(stat -f '%Sm' -t '%m/%d %H:%M' "$IN_APP")"
