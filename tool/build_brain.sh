#!/bin/bash
# brain CLI를 빌드해 앱 자산(assets/brain/)에 넣는다. 앱의 [연동]이 이 파일을 플러그인에 복사한다.
# flutter build/run 전에 실행한다 (정식 빌드는 tool/release.sh가 이 스크립트를 먼저 부른다). 결과 파일은 git에 올리지 않는다.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$REPO/packages/brain_cli" && dart build cli >/dev/null)
BUNDLE="$REPO/packages/brain_cli/build/cli/macos_arm64/bundle"
mkdir -p "$REPO/assets/brain/bin" "$REPO/assets/brain/lib"
cp "$BUNDLE/bin/brain" "$REPO/assets/brain/bin/brain"
cp "$BUNDLE/lib/libsqlite3.dylib" "$REPO/assets/brain/lib/libsqlite3.dylib"
# 어떤 소스로 빌드했는지 남긴다. 소스가 바뀌었는데 다시 빌드하지 않으면 자산 시험이 실패한다.
bash "$REPO/tool/brain_source_hash.sh" > "$REPO/assets/brain/SOURCE_HASH"
echo "assets/brain 갱신: $(du -sh "$REPO/assets/brain" | cut -f1), 소스 해시 $(cut -c1-12 "$REPO/assets/brain/SOURCE_HASH")"
