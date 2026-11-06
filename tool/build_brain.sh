#!/bin/bash
# brain CLI를 빌드해 앱 자산(assets/brain/)에 넣는다. 앱의 [연동]이 이 파일을 플러그인에 복사한다.
# flutter build/run 전에 한 번 실행한다. 결과 파일은 git에 올리지 않는다.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$REPO/packages/brain_cli" && dart build cli >/dev/null)
BUNDLE="$REPO/packages/brain_cli/build/cli/macos_arm64/bundle"
mkdir -p "$REPO/assets/brain/bin" "$REPO/assets/brain/lib"
cp "$BUNDLE/bin/brain" "$REPO/assets/brain/bin/brain"
cp "$BUNDLE/lib/libsqlite3.dylib" "$REPO/assets/brain/lib/libsqlite3.dylib"
echo "assets/brain 갱신: $(du -sh "$REPO/assets/brain" | cut -f1)"
