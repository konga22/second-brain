-- AI 크레딧 (설계서 6 v1.3.12·v1.3.30, 요금제분석 7절, 11/11 독립 검토 S-3·S-4·K-23).
-- 1크레딧 = API 원가 1원. 정수로 세려고 1크레딧 = 1,000,000 micro로 저장한다.
-- 흐름: 호출 전 "최대 원가"를 예약(reserve) → Anthropic 호출 → 실제 토큰으로 정산(settle, 실패면 0).
-- 질문·노트 내용은 저장하지 않는다. 숫자만.

create table public.ai_usage (
  user_id uuid not null references auth.users on delete cascade,
  month text not null,                          -- '2026-11' (UTC)
  spent_micro bigint not null default 0,        -- 확정된 원가
  reserved_micro bigint not null default 0,     -- 진행 중 호출의 최대 원가
  reserved_at timestamptz,
  window_start timestamptz not null default now(),
  window_calls int not null default 0,          -- 1분 창 안의 호출 수
  primary key (user_id, month)
);

alter table public.ai_usage enable row level security;
create policy "본인 크레딧 읽기" on public.ai_usage for select using (auth.uid() = user_id);
grant select on public.ai_usage to authenticated;
grant select, insert, update on public.ai_usage to service_role;

-- 예약: 한도·분당 호출 제한을 한 행 잠금 안에서 확인하고, 통과하면 최대 원가를 예약한다.
-- 5분 넘게 정산되지 않은 예약(함수가 죽은 경우)은 쓴 것으로 본다 — 원가 보호 쪽으로 틀린다.
create function public.reserve_credits(
  p_user uuid, p_month text, p_limit_micro bigint, p_max_cost_micro bigint, p_per_minute int
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r public.ai_usage%rowtype;
begin
  insert into public.ai_usage (user_id, month) values (p_user, p_month)
  on conflict (user_id, month) do nothing;
  select * into r from public.ai_usage where user_id = p_user and month = p_month for update;
  if r.reserved_micro > 0 and r.reserved_at < now() - interval '5 minutes' then
    r.spent_micro := r.spent_micro + r.reserved_micro;
    r.reserved_micro := 0;
  end if;
  if r.window_start < now() - interval '1 minute' then
    r.window_start := now();
    r.window_calls := 0;
  end if;
  if r.window_calls >= p_per_minute then
    update public.ai_usage set spent_micro = r.spent_micro, reserved_micro = r.reserved_micro,
      window_start = r.window_start, window_calls = r.window_calls
      where user_id = p_user and month = p_month;
    return jsonb_build_object('ok', false, 'reason', 'rate');
  end if;
  if r.spent_micro + r.reserved_micro + p_max_cost_micro > p_limit_micro then
    update public.ai_usage set spent_micro = r.spent_micro, reserved_micro = r.reserved_micro,
      window_start = r.window_start, window_calls = r.window_calls
      where user_id = p_user and month = p_month;
    return jsonb_build_object('ok', false, 'reason', 'credit',
      'remaining_micro', greatest(p_limit_micro - r.spent_micro - r.reserved_micro, 0));
  end if;
  update public.ai_usage set spent_micro = r.spent_micro,
    reserved_micro = r.reserved_micro + p_max_cost_micro, reserved_at = now(),
    window_start = r.window_start, window_calls = r.window_calls + 1
    where user_id = p_user and month = p_month;
  return jsonb_build_object('ok', true,
    'remaining_micro', p_limit_micro - r.spent_micro - r.reserved_micro - p_max_cost_micro);
end;
$$;

-- 정산: 예약을 풀고 실제 원가를 더한다. 호출이 실패했으면 p_actual_micro = 0 (환불).
create function public.settle_credits(
  p_user uuid, p_month text, p_reserved_micro bigint, p_actual_micro bigint
) returns bigint language sql security definer set search_path = '' as $$
  update public.ai_usage
     set reserved_micro = greatest(reserved_micro - p_reserved_micro, 0),
         spent_micro = spent_micro + greatest(p_actual_micro, 0)
   where user_id = p_user and month = p_month
  returning spent_micro;
$$;

revoke execute on function public.reserve_credits(uuid, text, bigint, bigint, int) from public, anon, authenticated;
revoke execute on function public.settle_credits(uuid, text, bigint, bigint) from public, anon, authenticated;
grant execute on function public.reserve_credits(uuid, text, bigint, bigint, int) to service_role;
grant execute on function public.settle_credits(uuid, text, bigint, bigint) to service_role;
