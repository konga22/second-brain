// AI 게이트웨이 공통 (설계서 6): 로그인 확인, 요금제·크레딧 확인, 응답 형식.
// 원칙: 요청 본문(질문·노트)은 어떤 로그에도 남기지 않는다. 남기는 것은 상태 코드·처리 시간·오류 이름뿐이다.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.119.0";
import type { Usage } from "./claude.ts";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

/** 앱이 보내는 요금제 값은 믿지 않는다. 서버가 profiles에서 읽는다 (설계서 1). */
export interface Caller {
  userId: string;
  plan: "free" | "pro";
  admin: SupabaseClient;
}

/** 서버 키. 새 키 체계(`SUPABASE_SECRET_KEYS`, JSON)를 먼저 읽고, 없으면 예전 변수를 쓴다 (11/11 검토 S-2:
 *  `SUPABASE_SERVICE_ROLE_KEY`는 레거시 키라 꺼져 있거나 없을 수 있다 — 검토자가 Supabase 문서로 확인). */
export function serverKey(): string {
  const dict = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (dict) {
    try {
      const parsed = JSON.parse(dict) as Record<string, string>;
      const key = parsed.default ?? Object.values(parsed)[0];
      if (key) return key;
    } catch {
      // 형식이 다르면 아래 예전 변수로
    }
  }
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!legacy) throw new Error("ServerKeyMissing");
  return legacy;
}

export async function authenticate(req: Request): Promise<Caller | Response> {
  const token = req.headers.get("Authorization")?.replace(/^Bearer /, "");
  if (!token) return json({ error: "로그인이 필요합니다." }, 401);
  // 서비스 키는 Supabase가 함수 환경변수로 넣어 준다. 코드·저장소에 넣지 않는다.
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, serverKey(), { auth: { persistSession: false } });
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return json({ error: "로그인이 만료됐습니다. 다시 로그인하세요." }, 401);
  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("plan, plan_renews_at")
    .eq("id", data.user.id)
    .maybeSingle();
  // 권한 문제로 못 읽었는데 조용히 무료로 취급하면 원인을 못 찾는다 (S-1). 오류로 끝낸다.
  if (profileError) throw new Error(`ProfilesRead:${profileError.code}`);
  const renews = profile?.plan_renews_at ? new Date(profile.plan_renews_at) : null;
  const isPro = profile?.plan === "pro" && (!renews || renews > new Date());
  return { userId: data.user.id, plan: isPro ? "pro" : "free", admin };
}

export function currentMonth(): string {
  const now = new Date();
  return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
}

// ---------- AI 크레딧 (설계서 6, 요금제분석 7절) ----------
// 1크레딧 = API 원가 1원 = 1,000,000 micro.

export const MICRO_PER_CREDIT = 1_000_000;

/** 월 크레딧 (가안, 미결정 5). 환경변수로 바꾼다. 무료 60, Pro 3,000. 숫자가 아니면 0(막는 쪽). */
export function monthlyCreditsMicro(plan: "free" | "pro"): number {
  const free = Number(Deno.env.get("FREE_MONTHLY_CREDITS") ?? "60");
  const pro = Number(Deno.env.get("PRO_MONTHLY_CREDITS") ?? "3000");
  const credits = plan === "pro" ? pro : free;
  return Number.isFinite(credits) && credits > 0 ? Math.round(credits * MICRO_PER_CREDIT) : 0;
}

/** 모델별 단가 ($/백만 토큰). 표에 없는 모델은 호출하지 않는다 (원가를 모르면 크레딧을 못 뺀다).
 *  출처: 요금제분석 1절 (Claude API 공식 모델 문서 기준, 11/07 확인). 값이 바뀌면 여기만 고친다. */
const PRICES: Record<string, { input: number; output: number }> = {
  "claude-haiku-5-5": { input: 0.10, output: 0.50 },
  "claude-sonnet-5-5": { input: 3.0, output: 15.0 },
};

export function price(model: string): { input: number; output: number } {
  const p = PRICES[model];
  if (!p) throw new Error("NoPriceForModel");
  return p;
}

/** 환율 (원/달러). 바뀌면 환경변수로. */
function krwPerUsd(): number {
  const v = Number(Deno.env.get("KRW_PER_USD") ?? "1340");
  return Number.isFinite(v) && v > 0 ? v : 1340;
}

/** 토큰 하나의 원가(micro). $/백만 토큰 × 원/달러 = 원/백만 토큰 = micro/토큰. */
function microPerToken(usdPerMillion: number): number {
  return usdPerMillion * krwPerUsd();
}

/** 실제 원가(micro). 캐시 쓰기는 입력의 1.25배, 캐시 읽기는 0.1배로 센다. */
export function costMicro(model: string, usage: Usage): number {
  const p = price(model);
  const input = usage.input_tokens +
    (usage.cache_creation_input_tokens ?? 0) * 1.25 +
    (usage.cache_read_input_tokens ?? 0) * 0.1;
  return Math.ceil(input * microPerToken(p.input) + usage.output_tokens * microPerToken(p.output));
}

/** 호출 전에 잡는 최대 원가. 입력은 글자 수를 토큰으로 보고(한국어 실측 1글자 ≈ 1토큰, 토큰분석) 1.5배 여유,
 *  출력은 max_tokens를 다 쓴다고 본다 (thinking 토큰도 출력에 들어간다). */
export function maxCostMicro(model: string, promptChars: number, maxTokens: number): number {
  const p = price(model);
  return Math.ceil((promptChars * 1.5 + 200) * microPerToken(p.input) + maxTokens * microPerToken(p.output));
}

export class CreditError extends Error {
  constructor(readonly reason: "rate" | "credit", readonly remainingMicro: number | null) {
    super(reason);
    this.name = "CreditError";
  }
}

/** 예약 → 실행 → 정산. 실패하면 정산액 0(환불), 거절이면 쓴 토큰만큼. 반환: 결과와 남은 크레딧(micro). */
export async function withCredits<T extends { usage: Usage }>(
  caller: Caller,
  model: string,
  maxCost: number,
  run: () => Promise<T>,
): Promise<{ result: T; remainingMicro: number }> {
  const month = currentMonth();
  const limit = monthlyCreditsMicro(caller.plan);
  const perMinute = Number(Deno.env.get("AI_CALLS_PER_MINUTE") ?? "10");
  const { data, error } = await caller.admin.rpc("reserve_credits", {
    p_user: caller.userId,
    p_month: month,
    p_limit_micro: limit,
    p_max_cost_micro: maxCost,
    p_per_minute: Number.isFinite(perMinute) && perMinute > 0 ? perMinute : 10,
  });
  if (error) throw new Error(`Reserve:${error.code}`);
  const reserved = data as { ok: boolean; reason?: "rate" | "credit"; remaining_micro?: number };
  if (!reserved.ok) throw new CreditError(reserved.reason ?? "credit", reserved.remaining_micro ?? null);
  let result: T;
  try {
    result = await run();
  } catch (error) {
    const usage = (error as { cause?: Usage }).cause;
    const actual = usage && typeof usage.input_tokens === "number" ? costMicro(model, usage) : 0;
    await settle(caller, month, maxCost, actual).catch(() => {});
    throw error;
  }
  const spent = await settle(caller, month, maxCost, costMicro(model, result.usage));
  return { result, remainingMicro: Math.max(limit - spent, 0) };
}

async function settle(caller: Caller, month: string, reserved: number, actual: number): Promise<number> {
  const { data, error } = await caller.admin.rpc("settle_credits", {
    p_user: caller.userId,
    p_month: month,
    p_reserved_micro: reserved,
    p_actual_micro: actual,
  });
  if (error) throw new Error(`Settle:${error.code}`);
  return Number(data ?? 0);
}

/** 크레딧 오류를 앱이 알아듣는 응답으로. */
export function creditResponse(error: CreditError, plan: "free" | "pro"): Response {
  return error.reason === "rate"
    ? json({ error: "잠시 너무 많이 물었습니다. 1분 뒤 다시 시도하세요.", plan }, 429)
    : json({ error: "이번 달 AI 크레딧을 다 썼습니다.", plan, remainingMicro: error.remainingMicro }, 402);
}

/** 검증은 크레딧과 별도로 하루 횟수도 막는다 (비싼 판정이 몰리는 것을 막는 안전장치). */
export async function consumeVerifyCall(caller: Caller): Promise<boolean> {
  const limit = Number(Deno.env.get("DAILY_VERIFY_CALLS") ?? (caller.plan === "pro" ? "200" : "20"));
  const { data, error } = await caller.admin.rpc("consume_verify_call", {
    p_user: caller.userId,
    p_day: new Date().toISOString().slice(0, 10),
    p_limit: limit,
  });
  if (error) throw new Error(`VerifyUsage:${error.code}`);
  return data !== -1;
}

// ---------- 입력 크기 (11/11 검토 S-3: 큰 입력 한 번에 원가가 크게 나가는데 서버가 자르지 않았다) ----------

/** 요청 본문 최대 크기. 노트 5개 × 500자 + 질문 2,000자 + 규칙 30줄이면 넉넉하다. */
export const MAX_BODY_BYTES = 64 * 1024;

/** 문자열만 받아 글자(코드 포인트) 단위로 자른다. 배열·객체가 오면 빈 문자열. */
export function str(value: unknown, max: number): string {
  if (typeof value !== "string") return "";
  const chars = [...value];
  return chars.length <= max ? value : `${chars.slice(0, max).join("")}…`;
}

/** 배열이면 앞에서 [max]개, 아니면 빈 배열. */
export function arr(value: unknown, max: number): unknown[] {
  return Array.isArray(value) ? value.slice(0, max) : [];
}

/** 본문을 읽어 JSON 객체로. 너무 크면 413, 형식이 틀리면 400 응답을 돌려준다. */
export async function readBody(req: Request): Promise<Record<string, unknown> | Response> {
  const text = await req.text();
  if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) {
    return json({ error: "요청이 너무 큽니다." }, 413);
  }
  try {
    const parsed = JSON.parse(text);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("NotObject");
    return parsed as Record<string, unknown>;
  } catch {
    return json({ error: "요청 형식이 잘못됐습니다." }, 400);
  }
}

/** 처리 결과만 남긴다 (본문 없음). 오류면 이름·코드만 (S-9: 500의 원인을 구분하려고). */
export function logResult(fn: string, status: number, startedAt: number, err?: string) {
  console.log(JSON.stringify({ fn, status, ms: Date.now() - startedAt, ...(err ? { err } : {}) }));
}
