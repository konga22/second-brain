// 크레딧 계산·입력 자르기 시험 (11/12, 설계서 6 v1.3.30). 네트워크 없이 돈다.
//   cd supabase/functions && deno test _shared/gateway_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1.0.13";
import { arr, costMicro, maxCostMicro, MICRO_PER_CREDIT, monthlyCreditsMicro, readBody, str } from "./gateway.ts";

Deno.test("Haiku 5.5 입력 6,000·출력 1,000토큰 원가는 약 1.47원 (요금제분석 어림 1.3원과 같은 크기)", () => {
  // 요금제분석 1절: 입력 약 6,000토큰 + 출력 약 1,000토큰 ≈ 1.3원 (환율 1,340원)
  const cost = costMicro("claude-haiku-5-5", { input_tokens: 6000, output_tokens: 1000 });
  const won = cost / MICRO_PER_CREDIT;
  assert(won > 1.4 && won < 1.5, `원가 ${won}원`); // 6000×0.000134 + 1000×0.00067 = 1.474원
});

Deno.test("캐시 읽기는 싸고 캐시 쓰기는 비싸게 센다", () => {
  const plain = costMicro("claude-haiku-5-5", { input_tokens: 1000, output_tokens: 0 });
  const read = costMicro("claude-haiku-5-5", { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 1000 });
  const write = costMicro("claude-haiku-5-5", { input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 1000 });
  assert(read < plain && plain < write);
});

Deno.test("최대 원가는 실제 원가보다 크게 잡는다 (예약이 모자라지 않게)", () => {
  const promptChars = 3000;
  const maxTokens = 4000;
  const reserve = maxCostMicro("claude-haiku-5-5", promptChars, maxTokens);
  // 실제로는 한글 1글자 ≈ 1토큰, 출력은 max_tokens 이하
  const actual = costMicro("claude-haiku-5-5", { input_tokens: promptChars + 150, output_tokens: maxTokens });
  assert(reserve >= actual, `예약 ${reserve} < 실제 ${actual}`);
});

Deno.test("단가표에 없는 모델은 원가를 못 세니 거절한다", () => {
  let threw = false;
  try {
    costMicro("claude-unknown", { input_tokens: 1, output_tokens: 1 });
  } catch {
    threw = true;
  }
  assert(threw);
});

Deno.test("월 크레딧: 무료 60, Pro 3,000, 숫자가 아니면 0", () => {
  assertEquals(monthlyCreditsMicro("free"), 60 * MICRO_PER_CREDIT);
  assertEquals(monthlyCreditsMicro("pro"), 3000 * MICRO_PER_CREDIT);
  Deno.env.set("FREE_MONTHLY_CREDITS", "abc");
  assertEquals(monthlyCreditsMicro("free"), 0);
  Deno.env.delete("FREE_MONTHLY_CREDITS");
});

Deno.test("str: 문자열만 받고 글자 단위로 자른다 (배열을 넣어도 통째로 나가지 않는다)", () => {
  assertEquals(str(["…1MB…"], 500), "");
  assertEquals(str({ a: 1 }, 500), "");
  assertEquals(str("가나다라", 2), "가나…");
  assertEquals(str("짧다", 10), "짧다");
  assertEquals(arr("문자열", 3), []);
  assertEquals(arr([1, 2, 3, 4], 2), [1, 2]);
});

Deno.test("readBody: 64KB가 넘으면 413, JSON이 아니면 400", async () => {
  const big = new Request("http://x", { method: "POST", body: JSON.stringify({ q: "가".repeat(30000) }) });
  const r1 = await readBody(big);
  assert(r1 instanceof Response && r1.status === 413);
  const bad = new Request("http://x", { method: "POST", body: "[1,2]" });
  const r2 = await readBody(bad);
  assert(r2 instanceof Response && r2.status === 400);
  const ok = new Request("http://x", { method: "POST", body: JSON.stringify({ task: "answer" }) });
  const r3 = await readBody(ok);
  assert(!(r3 instanceof Response) && r3.task === "answer");
});
