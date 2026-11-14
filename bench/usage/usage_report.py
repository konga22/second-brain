"""usage_extract.py 결과를 표로 낸다: 세션별 저장·교정·압축·모델, 모델별 토큰과 API 값 어림, 노트가 생긴 길.

  python3 -I bench/usage/usage_report.py <결과 폴더>
값은 정가 어림이다(캐시 쓰기는 1시간짜리 2배로 가정). 요금제 사용량과 다를 수 있다.
"""
import sys, os
if len(sys.argv) < 2: sys.exit('결과 폴더를 인자로 주세요')
os.chdir(sys.argv[1])

# ---- agg1.py ----
def _agg1():
    import json, collections, os, statistics as st
    S = json.load(open('sessions.json')); H = [json.loads(l) for l in open('human.jsonl')]
    top = [s for s in S if not s['sub']]; sub = [s for s in S if s['sub']]
    def lab(cwd):
        if not cwd: return '?'
        p = cwd.replace(os.path.expanduser('~'), '~')
        return p if len(p) < 46 else '…' + p[-44:]
    print('== 최상위 세션 (사람 문장 순) ==')
    print('사람문장 | AI메시지 | 압축 | 기간 | 모델 | 비용$ | brain add/lesson add/find/show | verifier | skill | 훅(prompt any/corr) | cwd')
    tot = collections.Counter()
    for s in sorted(top, key=lambda s: -s['n_human']):
        b = s['brain']; ag = s['agents']
        ver = sum(v for k, v in ag.items() if 'verifier' in k)
        sk = sum(v for k, v in s['skills'].items() if 'brain' in k)
        models = ','.join(f"{k.replace('claude-','')}:{v}" for k, v in sorted(s['models'].items(), key=lambda x: -x[1]))
        cost = s['cost']['total'] if s['cost'] else None
        print(f"{s['n_human']:4d} | {s['n_asst_msgs']:5d} | {len(s['compacts']):2d} | {(s['first'] or '')[5:10]}~{(s['last'] or '')[5:10]} | {models} | {cost and round(cost,2)} | {b.get('add',0)}/{b.get('lesson add',0)}/{b.get('find',0)}/{b.get('show',0)} | {ver} | {sk} | {s['hooks'].get('prompt:any',0)}/{s['hooks'].get('prompt:correction',0)} | {lab(s['cwd'])} [{os.path.basename(s['file'])[:8]}]")
        for k, v in b.items(): tot['brain ' + k] += v
        for k, v in ag.items(): tot['agent ' + k] += v
        for k, v in s['skills'].items(): tot['skill ' + k] += v
        for k, v in s['hooks'].items(): tot['hook ' + k] += v
        tot['compacts'] += len(s['compacts']); tot['stop_hooks'] += s['stop_hooks']; tot['stop_prevented'] += s['stop_prevented']
    print('\n== 합계 ==')
    for k, v in sorted(tot.items()): print(f'  {k}: {v}')
    print('\n== 하위 에이전트 기록 ==', len(sub))
    sb = collections.Counter(); sm = collections.Counter(); se = collections.Counter(); pb = 0
    for s in sub:
        for k, v in s['brain'].items(): sb[k] += v
        for k, v in s['models'].items(): sm[k] += v
        for k, v in s['effort'].items(): se[k] += v
        pb += s.get('prompt_has_brain') or 0
    print('  brain 명령:', dict(sb)); print('  모델(메시지 수):', dict(sm)); print('  effort:', dict(se)); print('  지시문에 세컨드 브레인/brain 언급:', pb, '/', len(sub))
    print('  SessionStart 훅 글이 든 하위 기록:', sum(1 for s in sub if s['hooks'].get('SessionStart') or s['hooks'].get('SessionStart(success)')))
    print('\n== 사람 문장 길이 ==')
    L = [len(h['text']) for h in H]
    print('  개수', len(L), '합계 글자', sum(L), '가운데', st.median(L), '평균', round(st.mean(L)), '300자 넘는 것', sum(1 for x in L if x > 300), '1000자 넘는 것', sum(1 for x in L if x > 1000))
    print('  300자로 자르면 합계', sum(min(x, 300) for x in L), ' 200자로', sum(min(x, 200) for x in L))
    print('\n== 버전/진입점 ==')
    v = collections.Counter(); e = collections.Counter()
    for s in top:
        for k, n in s['versions'].items(): v[k] += n
        for k, n in s['entry'].items(): e[k] += n
    print('  entry', dict(e)); print('  versions', len(v), sorted(v.items(), key=lambda x: -x[1])[:5])

_agg1()

# ---- agg3.py ----
def _agg3():
    import json, collections, os, re
    S = json.load(open('sessions.json'))
    PR = {'claude-opus-5-5': (4, 20, 0.2), 'claude-fable-5-2': (8, 40, 0.2), 'claude-fable-5-1': (10, 50, 0.25), 'claude-sonnet-5-5': (2, 10, 0.1), 'claude-haiku-5-5': (0.1, 0.5, 0.01), 'claude-opus-4-8': (5, 25, 0.5)}
    def cost(model, u):
        p = PR.get(model)
        if not p: return 0
        return (u.get('inp', 0) * p[0] + u.get('cw', 0) * p[0] * 2 + u.get('cr', 0) * p[2] + u.get('out', 0) * p[1]) / 1e6
    for label, grp in (('메인 세션', [s for s in S if not s['sub']]), ('하위 에이전트', [s for s in S if s['sub']])):
        tot = collections.defaultdict(collections.Counter); msgs = collections.Counter()
        for s in grp:
            for m, u in s['usage'].items():
                for k, v in u.items(): tot[m][k] += v
            for m, n in s['models'].items(): msgs[m] += n
        print('==', label, '==')
        allc = 0
        for m in sorted(tot, key=lambda m: -msgs[m]):
            u = tot[m]; c = cost(m, u); allc += c
            print(f"  {m}: 메시지 {msgs[m]}, 새 입력 {u['inp']/1e6:.2f}M, 캐시쓰기 {u['cw']/1e6:.1f}M, 캐시읽기 {u['cr']/1e6:.0f}M, 출력 {u['out']/1e6:.2f}M → API 값 어림 ${c:,.0f} (캐시읽기 몫 ${u['cr']*PR.get(m,(0,0,0))[2]/1e6:,.0f}, 캐시쓰기 몫 ${u['cw']*PR.get(m,(0,0,0))[0]*2/1e6:,.0f}, 출력 몫 ${u['out']*PR.get(m,(0,0,0))[1]/1e6:,.0f})")
        print(f'  합계 어림 ${allc:,.0f}')
    top = [s for s in S if not s['sub']]; sub = [s for s in S if s['sub']]
    am = collections.Counter(); at = collections.Counter(); ef = collections.Counter()
    for s in top:
        for k, v in s['agent_models'].items(): am[k] += v
        for k, v in s['agents'].items(): at[k] += v
        for k, v in s['effort'].items(): ef[k] += v
    print('\nAgent 호출 때 model 인자:', dict(am)); print('Agent 종류:', dict(at)); print('메인 effort(메시지 수):', dict(ef))
    # 하위 에이전트: 도구 섞임으로 일 종류 어림
    kinds = collections.Counter(); kc = collections.Counter(); kt = collections.Counter()
    for s in sub:
        t = s['tools']; n = sum(t.values()) or 1
        edit = t.get('Edit', 0) + t.get('Write', 0) + t.get('NotebookEdit', 0)
        k = '고치기·만들기(Edit/Write 있음)' if edit >= 3 else ('읽기·찾기·검토(Edit 거의 없음)')
        m = max(s['models'], key=s['models'].get) if s['models'] else '?'
        c = sum(cost(mm, u) for mm, u in s['usage'].items())
        kinds[(k, m)] += 1; kc[(k, m)] += c; kt[(k, m)] += n
    for k in sorted(kinds, key=lambda k: -kc[k]): print(f'  하위 {k}: {kinds[k]}개, 도구 호출 {kt[k]}, 어림 ${kc[k]:,.0f}')
    # 메인 세션: 도구 섞임
    tm = collections.Counter()
    for s in top:
        for k, v in s['tools'].items(): tm[k if not k.startswith('mcp__') else 'mcp__*'] += v
    print('\n메인 도구 호출 상위:', tm.most_common(14))

_agg3()

# ---- notes.py ----
def _notes():
    import os, re, glob, json, collections, datetime as dt
    V = os.path.expanduser('~/SecondBrain')
    E = json.load(open('brain_events.json')); H = [json.loads(l) for l in open('human.jsonl')]
    ASK = re.compile(r'저장|세컨드\s*브레인|노트|지식|정리해서|기억|brain')
    def fm(path):
        t = open(path, errors='replace').read(3000); m = re.match(r'---\n(.*?)\n---', t, re.S); d = {}
        if not m: return d
        for line in m.group(1).split('\n'):
            mm = re.match(r'^([a-zA-Z_-]+):\s*(.*)$', line)
            if mm: d[mm.group(1)] = mm.group(2)
        return d
    notes = []
    for p in glob.glob(V + '/wiki/**/*.md', recursive=True):
        d = fm(p)
        if d.get('id', '').startswith('n_'): notes.append(d)
    notes.sort(key=lambda d: d['id'])
    print('노트', len(notes), 'source', collections.Counter(d.get('source') for d in notes), 'status', collections.Counter(d.get('status') for d in notes))
    def parse(ts):
        try: return dt.datetime.fromisoformat(ts.replace('Z', '+00:00'))
        except Exception: return None
    adds = [(parse(e['ts']), e) for e in E if e['key'] == 'add' and parse(e['ts'])]
    kind = collections.Counter(); byday = collections.defaultdict(collections.Counter); detail = []
    for d in notes:
        c = parse(d.get('created', '')); best = None
        if c:
            for t, e in adds:
                diff = (c - t).total_seconds()
                if -5 <= diff <= 90 and (best is None or abs(diff) < abs(best[0])): best = (diff, e)
        if best:
            e = best[1]; h = H[e['human']] if e['human'] is not None else None
            k = '대화 중·사용자가 시킴' if (h and ASK.search(h['text'])) else ('하위 에이전트' if e['sub'] else '대화 중·AI가 알아서')
            sess = e['sess']
        else:
            k = '기록에 없음(앱의 지난 세션 정리·화면 없는 실행 등)'; sess = '-'
        kind[k] += 1; byday[(d.get('created') or '')[5:10]][k] += 1; detail.append((d['id'], (d.get('created') or '')[5:16], k, sess, re.sub(r'.*sessions/', '', d.get('sources', ''))[:28]))
    print(dict(kind))
    for day in sorted(byday): print(' ', day, dict(byday[day]))
    print()
    for x in detail: print(' ', *x)

_notes()
