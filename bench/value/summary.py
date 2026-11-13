"""python3 bench/value/summary.py <결과 jsonl> [bench/value/judge_20261108.json]

run.py 결과 요약: 조건별 정답률·토큰·턴·시간·비용(모델 환산), D 대비 짝 비교(부트스트랩 95% 구간)."""
import json, os, sys, random, statistics as st
from collections import defaultdict

rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
judged = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else {}
judged = judged.get('knowledge_overrides', judged)  # judge_*.json 형식도 받는다
rows = [r for r in rows if not r.get('error')]
for r in rows:
    key = f"{r['set']}|{r['id']}|{r['cond']}|{r['rep']}"
    if key in judged:
        r['ok'] = judged[key]

PRICE = {  # $/MTok: 입력, 캐시 쓰기(5분 1.25배), 캐시 읽기, 출력
    'opus': (4, 5, 0.20, 20), 'sonnet': (2, 2.5, 0.20, 10), 'haiku': (0.10, 0.125, 0.01, 0.50)}


def cost(r, m):
    a, w, rd, o = PRICE[m]
    return (r['input'] * a + r['cache_write'] * w + r['cache_read'] * rd + r['output'] * o) / 1e6


# 캐시 정규화: 시험은 4~8개를 동시에 돌려 캐시 적중이 우연에 좌우된다. 그래서
#  1) 모든 Claude Code가 함께 쓰는 앞부분(시스템 프롬프트·도구, 13,162토큰)은 늘 캐시 읽기
#  2) 조건별 고정 문맥(CLAUDE.md·스킬 목록·세션 안내 = 관계없는 요청의 최솟값 − 13,162)은
#     warm(한 시간 안에 Claude Code를 쓴 사용자) = 읽기, cold(그날 첫 세션) = 쓰기
#  3) 나머지(질문·도구 결과로 늘어난 부분)는 실측 그대로(쓰기·읽기 비율 유지)
CHUNK1 = 13162
BASE = {}


def set_base(rows):
    for c in 'ABCD':
        u = [r['input_total'] for r in rows if r['set'] == 'u' and r['cond'] == c]
        if u:
            BASE[c] = min(u)


def cost_norm(r, m, warm=True):
    a, w, rd, o = PRICE[m]
    chunk2 = BASE[r['cond']] - CHUNK1
    cw, cr = r['cache_write'], r['cache_read']
    # 이번 실행에서 고정 문맥을 썼나 읽었나 → 그만큼 빼서 '나머지'만 남긴다
    if cw >= 0.9 * chunk2:
        cw -= chunk2
    else:
        cr -= chunk2
    cr -= CHUNK1
    cw, cr = max(cw, 0), max(cr, 0)
    fixed = CHUNK1 * rd + (chunk2 * rd if warm else chunk2 * w)
    return (fixed + r['input'] * a + cw * w + cr * rd + r['output'] * o) / 1e6


import re
def real_leak(r):
    # 실제 지식 폴더·저장소를 읽으려 했거나, 없어야 할 조건(A)의 답에 노트 id가 나오면 누출
    t = any(re.search(re.escape(os.path.expanduser('~/SecondBrain')) + r'|/Volumes/SecondBrain', x) for x in r['tools'])
    return t or (r['cond'] == 'A' and bool(re.search(r'n_\d{4}|세컨드 ?브레인 노트', r.get('ans', ''))))


def boot(diffs, n=4000):
    random.seed(1)
    means = sorted(st.mean(random.choices(diffs, k=len(diffs))) for _ in range(n))
    return means[int(n * 0.025)], means[int(n * 0.975)]


set_base(rows)
for s in ('k', 'm', 'u'):
    sub = [r for r in rows if r['set'] == s]
    if not sub:
        continue
    print(f'\n## 세트 {s} ({len(sub)}회)')
    print('조건 | n | 정답/지킴 | 입력토큰 평균 | 중앙값 | 출력 | 턴 | 시간 중앙값(s) | Opus warm $ | Opus cold $ | Sonnet warm $ | 실제 Haiku $ | 누출')
    by = defaultdict(list)
    for r in sub:
        by[r['cond']].append(r)
    for c in sorted(by):
        g = by[c]
        oks = [r['ok'] for r in g if 'ok' in r]
        print(f"{c} | {len(g)} | {sum(oks)}/{len(oks) if oks else '-'} | {st.mean(r['input_total'] for r in g):,.0f} | "
              f"{st.median(r['input_total'] for r in g):,.0f} | {st.mean(r['output'] for r in g):,.0f} | {st.mean(r['turns'] for r in g):.2f} | "
              f"{st.median(r['ms'] for r in g)/1000:.1f} | {st.mean(cost_norm(r,'opus') for r in g):.4f} | {st.mean(cost_norm(r,'opus',False) for r in g):.4f} | {st.mean(cost_norm(r,'sonnet') for r in g):.4f} | "
              f"{st.mean(r['cost'] for r in g):.4f} | {sum(1 for r in g if real_leak(r))}")
    if s == 'k':
        for kind in ('P', 'G', 'N'):
            print(f'  [{kind}]', ' '.join(f"{c}:{sum(r['ok'] for r in by[c] if r['kind']==kind)}/{sum(1 for r in by[c] if r['kind']==kind)}" for c in sorted(by)))
    # D 대비 짝 비교 (같은 질문·같은 반복)
    idx = {(r['id'], r['rep'], r['cond']): r for r in sub}
    for c in sorted(by):
        if c == 'D':
            continue
        pairs = [(idx[(i, rp, c)], idx[(i, rp, 'D')]) for (i, rp, cc) in idx if cc == c and (i, rp, 'D') in idx]
        if not pairs:
            continue
        d_tok = [b['input_total'] - a['input_total'] for a, b in pairs]
        d_ms = [(b['ms'] - a['ms']) / 1000 for a, b in pairs]
        ratio = st.mean(b['input_total'] for a, b in pairs) / st.mean(a['input_total'] for a, b in pairs)
        lo, hi = boot(d_tok)
        lo2, hi2 = boot(d_ms)
        print(f'  D - {c}: 입력 {st.mean(d_tok):+,.0f} (95% {lo:+,.0f}~{hi:+,.0f}), D/{c} = {ratio:.2f}배, 시간 {st.mean(d_ms):+.1f}s ({lo2:+.1f}~{hi2:+.1f}), 짝 {len(pairs)}')
