// AI 게이트웨이 공통 (설계서 6): 로그인 확인, 요금제·사용량 확인, 응답 형식.
// 원칙: 요청 본문(질문·노트)은 어떤 로그에도 남기지 않는다. 남기는 것은 상태 코드와 처리 시간뿐이다.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

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

export async function authenticate(req: Request): Promise<Caller | Response> {
  const token = req.headers.get("Authorization")?.replace(/^Bearer /, "");
  if (!token) return json({ error: "로그인이 필요합니다." }, 401);
  // 서비스 키는 Supabase가 함수 환경변수로 넣어 준다. 코드·저장소에 넣지 않는다.
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return json({ error: "로그인이 만료됐습니다. 다시 로그인하세요." }, 401);
  const { data: profile } = await admin
    .from("profiles")
    .select("plan, plan_renews_at")
    .eq("id", data.user.id)
    .maybeSingle();
  const renews = profile?.plan_renews_at ? new Date(profile.plan_renews_at) : null;
  const isPro = profile?.plan === "pro" && (!renews || renews > new Date());
  return { userId: data.user.id, plan: isPro ? "pro" : "free", admin };
}

/** 월 한도 (가안, 설계서 6·미결정 5). 환경변수로 바꾼다. */
export function monthlyLimit(plan: "free" | "pro"): number {
  const free = Number(Deno.env.get("FREE_MONTHLY_AI_CALLS") ?? "50");
  const pro = Number(Deno.env.get("PRO_MONTHLY_AI_CALLS") ?? "1000");
  return plan === "pro" ? pro : free;
}

export function currentMonth(): string {
  const now = new Date();
  return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
}

/** 한 번 쓰고 남은 횟수를 돌려준다. 한도에 닿았으면 null. */
export async function consumeAiCall(caller: Caller): Promise<number | null> {
  const limit = monthlyLimit(caller.plan);
  const { data, error } = await caller.admin.rpc("consume_ai_call", {
    p_user: caller.userId,
    p_month: currentMonth(),
    p_limit: limit,
  });
  if (error) throw new Error(`사용량 확인 실패: ${error.code}`);
  return data === -1 ? null : limit - (data as number);
}

export async function consumeVerifyCall(caller: Caller): Promise<boolean> {
  const limit = Number(Deno.env.get("DAILY_VERIFY_CALLS") ?? (caller.plan === "pro" ? "200" : "20"));
  const { data, error } = await caller.admin.rpc("consume_verify_call", {
    p_user: caller.userId,
    p_day: new Date().toISOString().slice(0, 10),
    p_limit: limit,
  });
  if (error) throw new Error(`검증 사용량 확인 실패: ${error.code}`);
  return data !== -1;
}

/** 처리 결과만 남긴다 (본문 없음). */
export function logResult(fn: string, status: number, startedAt: number) {
  console.log(JSON.stringify({ fn, status, ms: Date.now() - startedAt }));
}
