#!/bin/bash
# brain CLI와 코어 소스(.dart, pubspec.yaml)의 해시 한 줄.
# build_brain.sh가 이 값을 assets/brain/SOURCE_HASH에 적고, test/plugin_assets_test.dart와 release.sh가 다시 계산해 견준다.
# 앱에 묶인 brain이 지금 소스로 빌드한 것인지 알기 위한 것이다 (11/11: 앱에 11/08 판이 묶여 있었다, 설계서 v1.3.27).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
{
  find packages/brain_cli/bin packages/brain_cli/lib packages/brain_core/lib -type f -name '*.dart'
  echo packages/brain_cli/pubspec.yaml
  echo packages/brain_core/pubspec.yaml
} | LC_ALL=C sort | while IFS= read -r file; do
  shasum -a 256 "$file"
done | shasum -a 256 | cut -d' ' -f1
