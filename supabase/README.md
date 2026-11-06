# Supabase (AI 게이트웨이)

설계서 4.3·6. 서버에는 요금제와 사용량만 있다. 노트·질문 내용은 저장하지 않고 로그에도 남기지 않는다.

## 처음 배포 (사용자가 직접)

키와 로그인은 사용자가 직접 넣는다. 저장소·앱 코드에는 어떤 키도 넣지 않는다.

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
supabase db push
```

Supabase 대시보드 → Edge Functions → Secrets에서 `ANTHROPIC_API_KEY`를 넣는다. 선택: `AI_MODEL`(기본 `claude-haiku-5-5`), `FREE_MONTHLY_AI_CALLS`(50), `PRO_MONTHLY_AI_CALLS`(1000), `DAILY_VERIFY_CALLS`.

```bash
supabase functions deploy ai-chat ai-verify mock-checkout
```

## 함수

| 함수 | 하는 일 | 사용량 |
|---|---|---|
| `ai-chat` | `task`: `answer`(노트 5개·규칙 3개 근거로 답, `usedNoteIds`), `expand_query`(검색어 3개), `name_groups`(묶음 이름) | 질문 1회당 1 (`expand_query`는 같은 질문에 포함) |
| `ai-verify` | `mode`: `correction`·`answer`·`missed`, 구조화된 판정(JSON) | 월 한도와 별도로 하루 한도 |
| `mock-checkout` | Pro 30일 켜기 (모의) | - |

- 모든 함수는 로그인 토큰을 확인하고, 요금제는 서버의 `profiles`에서 읽는다(앱이 보낸 값은 믿지 않음).
- 로그에는 `{fn, status, ms}`만 남긴다.
