#!/bin/bash
# 서버 마이그레이션을 로컬 Postgres에서 실제로 돌려 본다 (11/12, 설계서 6 v1.3.30).
# Supabase 프로젝트에 올리기 전에 SQL 문법·권한·크레딧 예약/정산·동시 호출을 확인한다.
# Supabase가 넣어 주는 것(auth.users, auth.uid(), anon·authenticated·service_role 역할)은 흉내 낸다.
#
#   brew install postgresql@17
#   bash supabase/tests/run_sql_tests.sh [작업 폴더(기본: 임시 폴더)]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PG=/opt/homebrew/opt/postgresql@17/bin
# macOS에서 로캘이 비면 postmaster가 시작 중에 멈춘다 ("became multithreaded during startup").
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
WORK="${1:-$(mktemp -d)}"
DATA="$WORK/pgdata"
"$PG/initdb" -D "$DATA" -U postgres --locale=C -E UTF8 >/dev/null
# 유닉스 소켓 경로는 103바이트 한도라 긴 작업 폴더에서 못 만든다 → 이 맥 안에서만 받는 TCP로.
"$PG/pg_ctl" -D "$DATA" -o "-p 54329 -c listen_addresses=localhost -c unix_socket_directories=''" -l "$WORK/pg.log" start >/dev/null
trap '"$PG/pg_ctl" -D "$DATA" stop -m fast >/dev/null' EXIT
psqlq() { "$PG/psql" -h localhost -p 54329 -U postgres -d postgres -v ON_ERROR_STOP=1 -qtA "$@"; }

# Supabase 흉내
psqlq <<'SQL'
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
SQL
for f in "$HERE"/../migrations/*.sql; do
  psqlq -f "$f" >/dev/null
  echo "[통과] 마이그레이션 $(basename "$f")"
done

U1=11111111-1111-1111-1111-111111111111
U2=22222222-2222-2222-2222-222222222222
psqlq -c "insert into auth.users (id) values ('$U1'), ('$U2');"
[ "$(psqlq -c "select count(*) from public.profiles")" = 2 ] && echo "[통과] 가입 트리거가 profiles 행을 만든다"

fail() { echo "[실패] $1"; exit 1; }
as_service() { psqlq -c "set role service_role; $1"; }

# 1) 예약·정산
R=$(as_service "select public.reserve_credits('$U1', '2026-11', 1000, 400, 10);")
echo "$R" | grep -q '"ok": true' || fail "예약 $R"
R=$(as_service "select public.reserve_credits('$U1', '2026-11', 1000, 400, 10);")
echo "$R" | grep -q '"ok": true' || fail "두 번째 예약 $R"
R=$(as_service "select public.reserve_credits('$U1', '2026-11', 1000, 400, 10);")
echo "$R" | grep -q '"reason": "credit"' || fail "한도 넘는 예약이 거절돼야 함: $R"
echo "[통과] 한도(1000) 안에서 400씩 두 번만 예약되고 세 번째는 거절"
S=$(as_service "select public.settle_credits('$U1', '2026-11', 400, 100);")
[ "$S" = 100 ] || fail "정산 뒤 쓴 양 100이어야 함: $S"
S=$(as_service "select public.settle_credits('$U1', '2026-11', 400, 0);")
[ "$S" = 100 ] || fail "실패한 호출은 0으로 정산(환불): $S"
[ "$(psqlq -c "select reserved_micro from public.ai_usage where user_id='$U1'")" = 0 ] || fail "예약이 남음"
echo "[통과] 정산: 실제 원가만 남고, 실패한 호출은 환불, 예약은 0"

# 2) 분당 호출 제한
for i in 1 2 3; do as_service "select public.reserve_credits('$U2', '2026-11', 100000, 1, 3);" >/dev/null; done
R=$(as_service "select public.reserve_credits('$U2', '2026-11', 100000, 1, 3);")
echo "$R" | grep -q '"reason": "rate"' || fail "분당 3번 넘으면 rate: $R"
echo "[통과] 분당 호출 제한 (3번 뒤 rate)"

# 3) 죽은 예약은 5분 뒤 쓴 것으로
psqlq -c "update public.ai_usage set reserved_micro = 500, reserved_at = now() - interval '6 minutes', window_calls = 0 where user_id='$U2';"
as_service "select public.reserve_credits('$U2', '2026-11', 100000, 1, 3);" >/dev/null
[ "$(psqlq -c "select spent_micro from public.ai_usage where user_id='$U2'")" = 500 ] || fail "죽은 예약이 쓴 양으로 옮겨져야 함"
echo "[통과] 5분 넘게 정산 안 된 예약은 쓴 것으로 (원가 보호)"

# 4) 동시 호출: 한도 1000, 한 번에 100씩 30개를 동시에 → 정확히 10개만 통과
psqlq -c "delete from public.ai_usage;"
for i in $(seq 1 30); do
  ( as_service "select public.reserve_credits('$U1', '2026-12', 1000, 100, 1000);" > "$WORK/c$i.out" ) &
done
wait
OK=$(cat "$WORK"/c*.out | grep -c '"ok": true' || true)
[ "$OK" = 10 ] || fail "동시 30개 중 통과 $OK (10이어야 함)"
[ "$(psqlq -c "select reserved_micro from public.ai_usage where user_id='$U1' and month='2026-12'")" = 1000 ] || fail "예약 합계"
echo "[통과] 동시 예약 30개 중 정확히 10개 (한도를 넘지 않음)"

# 5) 권한: 로그인한 사용자는 자기 행만 읽고, 고치거나 함수를 부르지 못한다
psqlq -c "insert into public.ai_usage (user_id, month) values ('$U2', '2026-12') on conflict do nothing;"
AS_U1="set role authenticated; set request.jwt.claim.sub = '$U1';"
[ "$(psqlq -c "$AS_U1 select count(*) from public.ai_usage")" = 1 ] || fail "본인 행만 보여야 함"
[ "$(psqlq -c "$AS_U1 select count(*) from public.profiles")" = 1 ] || fail "본인 요금제만 보여야 함"
echo "[통과] RLS: 본인 크레딧·요금제 행만 읽힘"
if psqlq -c "$AS_U1 update public.profiles set plan='pro' where id='$U1';" 2>/dev/null; then
  [ "$(psqlq -c "select plan from public.profiles where id='$U1'")" = free ] || fail "사용자가 자기 요금제를 pro로 바꿈"
fi
for fn in "reserve_credits('$U1','2026-12',99999999,1,10)" "settle_credits('$U1','2026-12',0,-999)" "consume_ai_call('$U1','2026-12',99)"; do
  if psqlq -c "$AS_U1 select public.$fn;" >/dev/null 2>&1; then fail "로그인 사용자가 $fn 을 부를 수 있음"; fi
done
if psqlq -c "set role anon; select count(*) from public.ai_usage;" >/dev/null 2>&1; then
  [ "$(psqlq -c "set role anon; select count(*) from public.ai_usage")" = 0 ] || fail "익명이 크레딧 행을 봄"
fi
echo "[통과] 권한: 요금제를 못 바꾸고, 크레딧·사용량 함수를 못 부르고, 익명은 아무 행도 못 봄"
echo "모두 통과"
