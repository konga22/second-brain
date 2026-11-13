#!/usr/bin/env bash
# 통합 시험을 한 명령으로 돌린다 (기능검토 K-38).
#
# `flutter test integration_test -d macos`처럼 파일 여러 개를 한 번에 주면 두 번째 파일부터 앱이
# 뜨지 않는다(11/12 확인). 그래서 파일마다 따로 `flutter test`를 부르고, 파일마다 지식 폴더 사본과
# 임시 설정 파일을 새로 만든다(실제 지식 폴더·설정 보호, 앞 시험이 남긴 상태가 다음 시험에 새지 않게).
#
#   bash tool/run_integration.sh                 # 기본 묶음
#   bash tool/run_integration.sh zoom graph_focus  # 고른 것만 (파일 이름에서 _test.dart를 뺀 것)
#
# 기본 묶음에서 빠진 것 (따로 돌린다):
#   past_sessions   실제 Claude Code를 불러 사용량이 든다
#   connect_install 이 맥의 Claude Code에 플러그인을 실제로 다시 설치한다(ALLOW_REAL_INSTALL=1)
#   first_index     노트 1만 개 폴더의 새 사본이 필요하다
#   startup_profile flutter drive --profile로 돌린다
#
# 사본 원본은 SOURCE_VAULT(기본 ~/SecondBrain). 임시 폴더는 맥 디스크(TMPDIR)에 만든다:
# USB 이미지 안 임시 폴더에서는 폴더 감시 시험이 흔들렸다(11/12, 작업일지).
set -uo pipefail

cd "$(dirname "$0")/.."
SOURCE_VAULT="${SOURCE_VAULT:-$HOME/SecondBrain}"
DEFAULT=(auto_tidy external_note graph_focus graph_untangle note_editor screens vault_missing zoom perf)
if [ $# -gt 0 ]; then TESTS=("$@"); else TESTS=("${DEFAULT[@]}"); fi

if [ ! -d "$SOURCE_VAULT" ]; then
  echo "사본을 만들 지식 폴더가 없다: $SOURCE_VAULT (SOURCE_VAULT로 고른다)" >&2
  exit 2
fi

# 시험 사본마다 색인이 ~/Library/Caches/<번들 ID>/<경로 해시>/에 생긴다. 시험 뒤 새로 생긴 것만 지운다.
CACHE_ROOT="$HOME/Library/Caches/com.konga22.secondbrain"
mkdir -p "$CACHE_ROOT"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sb_integration.XXXXXX")"
passed=()
failed=()
started=$(date +%s)

for name in "${TESTS[@]}"; do
  file="integration_test/${name}_test.dart"
  if [ ! -f "$file" ]; then
    echo "[없음] $file" >&2
    failed+=("$name(파일 없음)")
    continue
  fi
  work="$(mktemp -d "${TMPDIR:-/tmp}/sb_it_${name}.XXXXXX")"
  cp -R "$SOURCE_VAULT" "$work/vault"
  rm -f "$work/vault/_meta/index.db" "$work/vault/_meta/index.db-wal" "$work/vault/_meta/index.db-shm"
  log="$LOG_DIR/$name.log"
  caches_before="$(ls "$CACHE_ROOT")"
  t0=$(date +%s)
  printf '%-16s ' "$name"
  BRAIN_VAULT="$work/vault" BRAIN_CONFIG="$work/config.json" \
    flutter test "$file" -d macos >"$log" 2>&1
  code=$?
  t1=$(date +%s)
  if [ $code -eq 0 ] && grep -q "All tests passed" "$log"; then
    echo "통과 ($((t1 - t0))초)"
    passed+=("$name")
  else
    echo "실패 ($((t1 - t0))초) → $log"
    grep -E "Expected|Actual|Reason|EXCEPTION|Error:" "$log" | head -6 | sed 's/^/    /'
    failed+=("$name")
  fi
  rm -rf "$work"
  for d in $(ls "$CACHE_ROOT"); do
    if ! grep -qx "$d" <<<"$caches_before" && [ -f "$CACHE_ROOT/$d/index.db" ]; then rm -rf "${CACHE_ROOT:?}/$d"; fi
  done
done

echo
echo "통과 ${#passed[@]} / ${#TESTS[@]}, 걸린 시간 $(( $(date +%s) - started ))초, 기록 $LOG_DIR"
if [ ${#failed[@]} -gt 0 ]; then
  echo "실패: ${failed[*]}"
  exit 1
fi
