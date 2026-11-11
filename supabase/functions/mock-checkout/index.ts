// mock-checkout: 모의 결제 (설계서 6). 실제 결제는 하지 않고 Pro를 30일 켠다. 요금제 값은 서버가 정한다.
// Pro는 크레딧이 50배라 우리 원가가 든다. 시연 때만 켠다: 함수 환경변수 MOCK_CHECKOUT=on (11/11 검토 S-9).
import { authenticate, corsHeaders, json, logResult } from "../_shared/gateway.ts";
import { errorTag } from "../_shared/claude.ts";

Deno.serve(async (req) => {
  const startedAt = Date.now();
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (Deno.env.get("MOCK_CHECKOUT") !== "on") {
    logResult("mock-checkout", 403, startedAt);
    return json({ error: "모의 결제가 꺼져 있습니다." }, 403);
  }
  let caller;
  try {
    caller = await authenticate(req);
  } catch (error) {
    logResult("mock-checkout", 500, startedAt, errorTag(error));
    return json({ error: "서버 설정을 확인하지 못했습니다." }, 500);
  }
  if (caller instanceof Response) return caller;
  const renewsAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
  // 마이그레이션 전에 가입해 profiles 행이 없던 계정도 바뀌게 upsert, 실제로 1행이 바뀌었는지 본다 (S-9).
  const { data, error } = await caller.admin
    .from("profiles")
    .upsert({ id: caller.userId, plan: "pro", plan_renews_at: renewsAt })
    .select("id");
  if (error || !data || data.length !== 1) {
    logResult("mock-checkout", 500, startedAt, error ? `Profiles:${error.code}` : "NoRow");
    return json({ error: "요금제를 바꾸지 못했습니다." }, 500);
  }
  logResult("mock-checkout", 200, startedAt);
  return json({ plan: "pro", renewsAt });
});
