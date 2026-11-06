#!/bin/bash
# 개발용: brain CLI를 빌드하고 Claude Code 플러그인을 이 맥에 설치한다.
# 앱의 [연동] 버튼과 같은 일을 한다 (lib/core/claude_code_installer.dart).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOT="$HOME/Library/Application Support/com.konga22.secondbrain/claude-code"
PLUGIN="$ROOT/second-brain"

(cd "$REPO/packages/brain_cli" && dart build cli >/dev/null)
BUNDLE="$REPO/packages/brain_cli/build/cli/macos_arm64/bundle"

rm -rf "$PLUGIN"
mkdir -p "$ROOT/.claude-plugin" "$PLUGIN/.claude-plugin" "$PLUGIN/hooks" "$PLUGIN/bin" "$PLUGIN/lib"
cp "$HERE/marketplace.json" "$ROOT/.claude-plugin/marketplace.json"
cp "$HERE/plugin.json" "$PLUGIN/.claude-plugin/plugin.json"
cp "$HERE/hooks.json" "$PLUGIN/hooks/hooks.json"
cp -R "$HERE/skills" "$PLUGIN/skills"
cp "$BUNDLE/bin/brain" "$PLUGIN/bin/brain"
cp "$BUNDLE/lib/libsqlite3.dylib" "$PLUGIN/lib/libsqlite3.dylib"
chmod +x "$PLUGIN/bin/brain"

claude plugin validate "$ROOT"
if claude plugin marketplace list 2>/dev/null | grep -q second-brain-local; then
  claude plugin marketplace update second-brain-local
else
  claude plugin marketplace add "$ROOT"
fi
claude plugin install second-brain@second-brain-local
echo "설치 끝: $PLUGIN"
