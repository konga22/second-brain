// 홍보 페이지 첫 화면 그래프가 실제로 그려지는지 확인한다 (기능검토 K-14, 2026-11-09).
// Chrome을 개발자 프로토콜로 띄워 데스크톱·휴대폰(터치·iPhone)·동작 줄이기 환경마다 3번씩
// 6초 기다린 뒤 #graph 캔버스에 그려진 점 수와 페이지 예외를 센다. 하나라도 0이거나 예외가 있으면 실패(종료 코드 1).
//
//   node --experimental-websocket web/check-graph.mjs [주소=https://second-brain-cvj.pages.dev/]
//
// 주의: 앱 안 브라우저 창이 숨겨져 있거나 뒤쪽 탭이면 화면 갱신이 멈춰 "캔버스는 있는데 비어 있음"이 거짓으로 나온다.
// 그래서 탭을 앞으로 가져오고(Page.bringToFront) 실제 시간으로 기다린다.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const url = process.argv[2] ?? 'https://second-brain-cvj.pages.dev/';
const chromePath = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const port = 9300 + Math.floor(Math.random() * 500);
const profile = mkdtempSync(join(tmpdir(), 'graph-check-'));
const chrome = spawn(chromePath, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--no-first-run', 'about:blank'], { stdio: 'ignore' });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitChrome() {
  for (let i = 0; i < 50; i++) {
    try { await fetch(`http://127.0.0.1:${port}/json/version`); return; } catch { await sleep(200); }
  }
  throw new Error('Chrome이 뜨지 않음');
}

const iphoneUa = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const envs = {
  데스크톱: { metrics: { width: 1280, height: 900, deviceScaleFactor: 2, mobile: false } },
  휴대폰: { metrics: { width: 390, height: 844, deviceScaleFactor: 3, mobile: true }, touch: true, ua: iphoneUa },
  '동작 줄이기': { metrics: { width: 390, height: 844, deviceScaleFactor: 3, mobile: true }, touch: true, ua: iphoneUa, reduce: true },
};

async function run(env) {
  const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r, { once: true }));
  let id = 0;
  const pending = new Map();
  const errors = [];
  ws.addEventListener('message', (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    else if (m.method === 'Runtime.exceptionThrown') errors.push((m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text).split('\n')[0]);
  });
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  await send('Page.enable');
  await send('Page.bringToFront');
  await send('Runtime.enable');
  await send('Network.setCacheDisabled', { cacheDisabled: true });
  await send('Emulation.setDeviceMetricsOverride', env.metrics);
  if (env.touch) await send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
  if (env.ua) await send('Emulation.setUserAgentOverride', { userAgent: env.ua });
  if (env.reduce) await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
  await send('Page.navigate', { url });
  await sleep(6000);
  const probe = `(() => { const c = document.querySelector('#graph canvas'); if (!c) return -1; const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; let lit = 0; for (let i = 3; i < d.length; i += 4) if (d[i] > 20) lit++; return lit; })()`;
  const r = await send('Runtime.evaluate', { expression: probe, returnByValue: true });
  ws.close();
  await fetch(`http://127.0.0.1:${port}/json/close/${target.id}`).catch(() => {});
  return { lit: r.result?.result?.value ?? -1, errors };
}

let failed = false;
try {
  await waitChrome();
  for (const [name, env] of Object.entries(envs)) {
    const results = [];
    for (let i = 0; i < 3; i++) results.push(await run(env));
    const bad = results.some((x) => x.lit <= 0 || x.errors.length > 0);
    failed ||= bad;
    console.log(`${bad ? '실패' : '통과'}  ${name}: 그려진 점 ${results.map((x) => x.lit).join(' / ')}${results.some((x) => x.errors.length) ? `  예외: ${[...new Set(results.flatMap((x) => x.errors))].join(' | ')}` : ''}`);
  }
} finally {
  // Chrome이 완전히 끝난 뒤 임시 프로필을 지운다 (끝나기 전에 지우면 ENOTEMPTY)
  const exited = new Promise((r) => chrome.once('exit', r));
  chrome.kill();
  await Promise.race([exited, sleep(3000)]);
  try { rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch {}
}
process.exit(failed ? 1 : 0);
