# Supabase (AI 게이트웨이)

설계서 4.3·6. 서버에는 요금제와 AI 크레딧 숫자만 있다. 노트·질문 내용은 저장하지 않고 로그에도 남기지 않는다(로그는 함수 이름·상태 코드·처리 시간·오류 이름뿐).

## 배포 전에 이 맥에서 확인 (11/12부터 가능)

```bash
brew install deno postgresql@17
```

```bash
cd supabase/functions && deno check ai-chat/index.ts ai-verify/index.ts mock-checkout/index.ts
```

```bash
cd supabase/functions && deno test --allow-env _shared/gateway_test.ts
```

```bash
bash supabase/tests/run_sql_tests.sh
```

- `deno check`: 세 함수 타입 검사.
- `gateway_test.ts`: 크레딧 원가 계산, 예약이 실제 원가보다 큰지, 입력 자르기, 64KB 넘는 요청 413.
- `run_sql_tests.sh`: 로컬 Postgres에 마이그레이션을 실제로 올리고 권한·예약·정산·분당 제한·동시 호출 30개·RLS를 확인한다(Supabase의 `auth` 스키마와 역할은 흉내 냄).

## 처음 배포 (사용자가 직접)

키와 로그인은 사용자가 직접 넣는다. 저장소·앱 코드에는 어떤 키도 넣지 않는다.

**0. 대시보드 먼저 확인**
- 프로젝트가 멈춰 있지 않은가: 무료 프로젝트는 7일 동안 활동이 없으면 멈춘다(11/06에 만들고 쓰지 않았음). 멈췄으면 [Restore].
- Settings → API Keys: 비밀 키(`sb_secret_…`) 또는 레거시 `service_role` 키가 있는가. 함수는 `SUPABASE_SECRET_KEYS`(새 키)를 먼저, 없으면 `SUPABASE_SERVICE_ROLE_KEY`를 읽는다.
- Authentication → Sign In / Providers: 이메일 가입. 기본 메일 발송은 팀 주소에만 가고 시간당 2통이라, **시연 계정은 Authentication → Users → [Add user]로 직접 만들고(자동 확인)** 공개 가입은 끄는 것을 권한다.
- Authentication → URL Configuration → Site URL: 홍보 페이지 주소(https://second-brain-cvj.pages.dev/)로. 기본 `localhost:3000`이면 확인 메일 링크가 "연결 안 됨"으로 보인다.
- Anthropic Console → Limits: 월 지출 한도를 낮게 걸어 둔다(서버 코드가 막지 못하는 경우의 마지막 안전장치).

**1. 설치·연결·마이그레이션**

```bash
brew install supabase/tap/supabase
```

```bash
supabase login
```

```bash
supabase link --project-ref <프로젝트 ref>
```

```bash
supabase db push --dry-run
```

```bash
supabase db push
```

- `--dry-run`에 `20261106000000_init.sql`, `20261112000000_credits.sql` 두 개가 보여야 한다.

**2. 비밀 값 (Edge Functions → Secrets)**

| 이름 | 필수 | 값 |
|---|---|---|
| `ANTHROPIC_API_KEY` | 예 | Anthropic API 키 |
| `AI_MODEL` | 아니오 | 기본 `claude-haiku-5-5`. 단가표(`_shared/gateway.ts` `PRICES`)에 있는 모델만 |
| `FREE_MONTHLY_CREDITS` / `PRO_MONTHLY_CREDITS` | 아니오 | 기본 60 / 3000 (1크레딧 = 원가 1원) |
| `KRW_PER_USD` | 아니오 | 기본 1340 |
| `AI_CALLS_PER_MINUTE` | 아니오 | 기본 10 (사용자당 분당 호출) |
| `DAILY_VERIFY_CALLS` | 아니오 | 기본 무료 20 / Pro 200 |
| `MOCK_CHECKOUT` | 시연 때만 | `on`이면 모의 결제가 Pro를 켠다. 없으면 403 |

**3. 함수 배포**

```bash
supabase functions deploy ai-chat
```

```bash
supabase functions deploy ai-verify
```

```bash
supabase functions deploy mock-checkout
```

- 함수 로그에 `BOOT_ERROR`가 없는지 본다.
- 게이트웨이가 401 "Invalid JWT"를 내면 `config.toml`의 `verify_jwt`를 `false`로 바꾼다(함수가 `getUser`로 다시 확인하므로 안전하다). 새 서명 키에서 이 설정이 어떻게 동작하는지는 확인하지 못했다.

## 배포 직후 시험 순서

1. **SQL 권한**: SQL 편집기에서 `select has_function_privilege('service_role', 'public.reserve_credits(uuid,text,bigint,bigint,int)', 'execute');` → `true`.
2. **가입·로그인**: 시연 계정으로 로그인 → `profiles`에 행이 있는지.
3. **질문**: 앱에서 근거가 있는 질문 1번 → 답과 근거 노트가 보이고, `ai_usage.spent_micro`가 늘었는지. Anthropic Console의 토큰 수로 원가를 맞춰 본다(1회 약 1.3~1.5원 가정).
4. **권한 (본인 토큰으로 curl)**: 토큰 없음 → 401, `task: "x"` → 400, 64KB 넘는 본문 → 413, REST로 `profiles` 고치기 → 막힘.
5. **한도**: `FREE_MONTHLY_CREDITS=2`로 낮춰 두 번째 질문에 402와 앱 문구 → 값 되돌리기. `AI_CALLS_PER_MINUTE=2`로 낮춰 세 번째에 429.
6. **검증**: 실수 노트가 걸리는 질문에서 pass 또는 rewrite. `DAILY_VERIFY_CALLS=1`이면 두 번째 답이 "검증 전"으로 그대로 보이는지.
7. **모의 결제**: `MOCK_CHECKOUT=on`에서 무료 → Pro, 앱의 크레딧 한도가 3,000으로.
8. **실패 경로**: 틀린 API 키 → 500이고 크레딧이 빠지지 않는지(정산 0). 앱을 오프라인으로 → "인터넷에 연결되어 있지 않습니다".

## 함수

| 함수 | 하는 일 | 크레딧 |
|---|---|---|
| `ai-chat` | `task`: `answer`(노트 5개·규칙 최대 30줄 근거로 답, `usedNoteIds`), `expand_query`(검색어 3개), `name_groups`(묶음 이름) | 모든 task가 쓴 토큰만큼 |
| `ai-verify` | `mode`: `correction`·`answer`·`missed`, 구조화된 판정(JSON) | 쓴 토큰만큼 + 하루 횟수 한도 |
| `mock-checkout` | Pro 30일 켜기 (모의, `MOCK_CHECKOUT=on`일 때만) | - |

- **크레딧 흐름**: 호출 전 최대 원가를 예약(`reserve_credits`, 한도·분당 제한을 한 행 잠금 안에서 확인) → Anthropic 호출 → 실제 토큰으로 정산(`settle_credits`, 실패면 0 = 환불). 5분 넘게 정산되지 않은 예약은 쓴 것으로 본다.
- 모든 함수는 로그인 토큰을 확인하고, 요금제는 서버의 `profiles`에서 읽는다(앱이 보낸 값은 믿지 않음). 차감 여부도 서버가 정한다(예전의 `countUsage`는 없앰).
- 요청 본문은 64KB까지, 모든 글자 칸은 서버가 길이를 자른다.
- 버전 고정: `@anthropic-ai/sdk@1.7.0`, `@supabase/supabase-js@2.119.0`, `zod@4.6.7` (11/12 `deno check` 통과).
