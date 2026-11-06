-- 세컨드 브레인 서버 스키마 (설계서 4.3). 요금제와 사용량만 저장한다.
-- 노트·질문·답변 내용은 어떤 테이블에도 두지 않는다 (설계서 1 원칙 "지식은 기기에").

create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  plan text not null default 'free' check (plan in ('free', 'pro')),
  plan_renews_at timestamptz,
  created_at timestamptz not null default now()
);

-- 앱 안 AI 질문(경로 B)만 센다. 경로 A(사용자 AI)는 서버를 거치지 않아 세지 않는다.
create table public.usage (
  user_id uuid not null references auth.users on delete cascade,
  month text not null,                       -- '2026-11'
  ai_calls int not null default 0,
  primary key (user_id, month)
);

-- 검증(ai-verify)은 질문 1회에 포함하되 따로 하루 한도를 둔다 (설계서 6).
create table public.verify_usage (
  user_id uuid not null references auth.users on delete cascade,
  day date not null,
  calls int not null default 0,
  primary key (user_id, day)
);

-- RLS: 본인 행만 읽는다. 쓰기는 Edge Function(서비스 키)만 한다 (정책이 없으면 막힘).
alter table public.profiles enable row level security;
alter table public.usage enable row level security;
alter table public.verify_usage enable row level security;

create policy "본인 요금제 읽기" on public.profiles
  for select using (auth.uid() = id);
create policy "본인 사용량 읽기" on public.usage
  for select using (auth.uid() = user_id);
create policy "본인 검증 사용량 읽기" on public.verify_usage
  for select using (auth.uid() = user_id);

-- 가입하면 무료 요금제 행을 만든다.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 사용량 1 올리기. 한도에 닿았으면 올리지 않고 -1을 돌려준다 (동시에 와도 한도를 넘지 않게 한 문장으로).
create function public.consume_ai_call(p_user uuid, p_month text, p_limit int)
returns int language plpgsql security definer set search_path = '' as $$
declare
  used int;
begin
  insert into public.usage (user_id, month, ai_calls) values (p_user, p_month, 0)
  on conflict (user_id, month) do nothing;
  update public.usage set ai_calls = ai_calls + 1
    where user_id = p_user and month = p_month and ai_calls < p_limit
    returning ai_calls into used;
  return coalesce(used, -1);
end;
$$;

create function public.consume_verify_call(p_user uuid, p_day date, p_limit int)
returns int language plpgsql security definer set search_path = '' as $$
declare
  used int;
begin
  insert into public.verify_usage (user_id, day, calls) values (p_user, p_day, 0)
  on conflict (user_id, day) do nothing;
  update public.verify_usage set calls = calls + 1
    where user_id = p_user and day = p_day and calls < p_limit
    returning calls into used;
  return coalesce(used, -1);
end;
$$;

-- 사용량 함수는 서비스 키로만 부른다.
revoke execute on function public.consume_ai_call(uuid, text, int) from public, anon, authenticated;
revoke execute on function public.consume_verify_call(uuid, date, int) from public, anon, authenticated;
