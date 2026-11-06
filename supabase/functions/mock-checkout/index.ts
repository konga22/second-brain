// mock-checkout: 모의 결제 (설계서 6). 실제 결제는 하지 않고 Pro를 30일 켠다. 요금제 값은 서버가 정한다.
import { authenticate, corsHeaders, json, logResult } from "../_shared/gateway.ts";

Deno.serve(async (req) => {
  const startedAt = Date.now();
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const caller = await authenticate(req);
  if (caller instanceof Response) return caller;
  const renewsAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
  const { error } = await caller.admin
    .from("profiles")
    .update({ plan: "pro", plan_renews_at: renewsAt })
    .eq("id", caller.userId);
  if (error) {
    logResult("mock-checkout", 500, startedAt);
    return json({ error: "요금제를 바꾸지 못했습니다." }, 500);
  }
  logResult("mock-checkout", 200, startedAt);
  return json({ plan: "pro", renewsAt });
});
