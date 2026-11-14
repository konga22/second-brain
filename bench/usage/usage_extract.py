"""Claude Code 대화 기록(~/.claude/projects)에서 쓰임 숫자를 뽑는다 — 읽기 전용, 이 맥에서만 돈다(AI 호출 없음).

뽑는 것: 사람이 쓴 문장, 도구 호출 이름, `brain` 명령 머리, 훅이 넣은 글의 종류, 모델·노력 수준·토큰.
세션을 이어 열거나 갈라 낸 복사본은 줄 uuid로 한 번만 센다.

결과(sessions.json, human.jsonl, brain_events.json)에는 사용자 문장이 그대로 들어간다 → 저장소 밖에만 둔다.
  python3 -I bench/usage/usage_extract.py <결과 폴더(저장소 밖)>
  python3 -I bench/usage/usage_report.py <결과 폴더>
근거: docs/기능추천.md (작업 지시서 8번, 2026-11-14)
"""
import json, glob, os, re, collections, sys
ROOT = os.path.expanduser('~/.claude/projects')
if len(sys.argv) < 2: sys.exit('결과 폴더를 인자로 주세요 (저장소 밖 — 사용자 문장이 들어갑니다)')
OUT = os.path.abspath(sys.argv[1]); os.makedirs(OUT, exist_ok=True)
if os.path.exists(os.path.join(OUT, '.git')) or '/second-brain/' in OUT + '/': sys.exit('저장소 안에는 쓰지 않습니다')
SYS_PAT = re.compile(r'^\s*(<task-notification>|\[SYSTEM NOTIFICATION|<system-reminder|\[Subagent hand-back\]|<agent-message |<command-name>|<local-command|Caveat:|\[Request interrupted|<bash-input>|<bash-stdout>|<user-memory-input>|This session is being continued|<side-sessions-event|<ci-monitor-event|<teammate-message)')
STRIP = re.compile(r'<system-reminder>.*?</system-reminder>', re.S)
BRAIN = re.compile(r'(?:^|[\s;&|(`"\'/])brain\s+([a-z][a-z-]*)(?:\s+([a-z][a-z-]*))?')
def text_of(content):
    if isinstance(content, str): return content
    if isinstance(content, list):
        return '\n'.join(b.get('text', '') for b in content if isinstance(b, dict) and b.get('type') == 'text')
    return ''
def is_human(o, txt):
    if o.get('isMeta') or o.get('isCompactSummary') or 'toolUseResult' in o: return False
    c = (o.get('message') or {}).get('content')
    if isinstance(c, list) and any(isinstance(b, dict) and b.get('type') == 'tool_result' for b in c): return False
    kind = (o.get('origin') or {}).get('kind'); to = o.get('turnOrigin')
    if kind and kind != 'human': return False
    if to and to != 'human': return False
    if SYS_PAT.search(txt): return False
    return bool(txt.strip())
sessions = []; humans = []; SEEN = set(); SEEN_MSG = {}; DUP = [0]; BEV = []; TU = {}
def parse(path, sub=False):
    s = dict(file=path, sub=sub, cwd=None, first=None, last=None, n_human=0, n_asst_msgs=0, models=collections.Counter(), effort=collections.Counter(),
             usage=collections.defaultdict(lambda: collections.Counter()), tools=collections.Counter(), brain=collections.Counter(), agents=collections.Counter(), agent_models=collections.Counter(),
             skills=collections.Counter(), compacts=[], cost=None, hooks=collections.Counter(), versions=collections.Counter(), entry=collections.Counter(), stop_hooks=0, stop_prevented=0)
    seen_msg = SEEN_MSG; cur = None; last_asst_text = ''
    with open(path, errors='replace') as fh:
        for line in fh:
            try: o = json.loads(line)
            except Exception: continue
            t = o.get('type'); ts = o.get('timestamp')
            if t in ('user', 'assistant', 'attachment', 'system') and o.get('uuid'):
                if o['uuid'] in SEEN:
                    DUP[0] += 1
                    if t == 'assistant':
                        for b in (o.get('message') or {}).get('content') or []:
                            if isinstance(b, dict) and b.get('type') == 'text': last_asst_text = b.get('text') or last_asst_text
                    continue
                SEEN.add(o['uuid'])
            if t == 'user' and 'toolUseResult' in o:
                for b in (o.get('message') or {}).get('content') or []:
                    if isinstance(b, dict) and b.get('type') == 'tool_result' and b.get('tool_use_id') in TU:
                        c = b.get('content'); r = c if isinstance(c, str) else ' '.join(x.get('text', '') for x in c if isinstance(x, dict)) if isinstance(c, list) else ''
                        TU[b['tool_use_id']]['res'] = r[:200]; TU[b['tool_use_id']]['err'] = bool(b.get('is_error'))
            if ts and isinstance(ts, str):
                s['first'] = s['first'] or ts; s['last'] = ts
            if o.get('cwd') and not s['cwd']: s['cwd'] = o['cwd']
            if t == 'cost-state': s['cost'] = dict(total=o.get('totalCostUSD'), models={k: v.get('costUSD') for k, v in (o.get('modelUsage') or {}).items()}, dur=o.get('totalDuration')); continue
            if t == 'system':
                st = o.get('subtype')
                if st == 'compact_boundary':
                    m = o.get('compactMetadata') or {}
                    s['compacts'].append(dict(ts=ts, trigger=m.get('trigger'), pre=m.get('preTokens'), post=m.get('postTokens'), at_human=s['n_human']))
                    if cur is not None: cur['after']['compact'] += 1
                elif st == 'stop_hook_summary':
                    s['stop_hooks'] += 1
                    if o.get('preventedContinuation'): s['stop_prevented'] += 1
                continue
            if t == 'attachment':
                a = o.get('attachment') or {}
                if a.get('type') == 'hook_additional_context':
                    ev = a.get('hookEvent'); txt = '\n'.join(x for x in (a.get('content') or []) if isinstance(x, str))
                    kinds = []
                    if ev == 'UserPromptSubmit':
                        if '사용자의 실수 노트' in txt: kinds.append('lesson')
                        if '만들기 요청이다' in txt: kinds.append('build')
                        if '이 요청과 맞는 노트가 있다' in txt: kinds.append('known')
                        if '앞 답을 고치는 것 같다면' in txt: kinds.append('correction')
                        if not kinds: kinds.append('other')
                        for k in kinds: s['hooks']['prompt:' + k] += 1
                        s['hooks']['prompt:any'] += 1
                        if cur is not None:
                            cur['hook'] = kinds; cur['hook_len'] = len(txt)
                            cur['hook_ids'] = sorted(set(re.findall(r'\b(L-\d{4}|n_\d{4})\b', txt)))
                    else:
                        s['hooks'][f'{ev}'] += 1
                        if ev == 'SessionStart':
                            s['hooks']['SessionStart:brain'] += int('[세컨드 브레인]' in txt)
                            s['hooks']['SessionStart:autosave'] += int('자동 저장' in txt)
                            s.setdefault('ss_len', []).append(len(txt))
                elif a.get('type') == 'hook_success' and a.get('hookEvent') == 'SessionStart':
                    out = (a.get('stdout') or '') + (a.get('content') or '')
                    s['hooks']['SessionStart(success)'] += 1
                    s['hooks']['SessionStart:brain'] += int('[세컨드 브레인]' in out)
                    s['hooks']['SessionStart:autosave'] += int('자동 저장' in out)
                continue
            if t == 'user':
                s['versions'][o.get('version')] += 1; s['entry'][o.get('entrypoint')] += 1
                txt = STRIP.sub('', text_of((o.get('message') or {}).get('content'))).strip()
                if not sub and is_human(o, txt):
                    s['n_human'] += 1
                    cur = dict(uuid=o.get('uuid'), i=len(humans), sess=os.path.basename(path)[:8], file=path, cwd=o.get('cwd') or s['cwd'], ts=ts, n=s['n_human'], text=txt,
                               prev=last_asst_text[-400:], hook=[], hook_len=0, hook_ids=[], after=collections.Counter(), after_brain=[], after_agents=[], after_skills=[], asst_text_len=0)
                    humans.append(cur)
                elif sub and s.get('prompt_len') is None and txt:
                    s['prompt_len'] = len(txt)
                    s['prompt_has_brain'] = int('세컨드 브레인' in txt or 'brain ' in txt)
                continue
            if t == 'assistant':
                m = o.get('message') or {}; mid = m.get('id') or o.get('uuid'); model = m.get('model')
                if model == '<synthetic>': continue
                u = m.get('usage') or {}
                if mid not in seen_msg:
                    s['n_asst_msgs'] += 1; s['models'][model] += 1; s['effort'][str(o.get('effort'))] += 1
                prevu = seen_msg.get(mid, {})
                newu = dict(inp=u.get('input_tokens') or 0, cw=u.get('cache_creation_input_tokens') or 0, cr=u.get('cache_read_input_tokens') or 0, out=u.get('output_tokens') or 0)
                for k in newu:  # 같은 메시지가 여러 줄로 나뉨 → 가장 큰 값만
                    d = max(newu[k], prevu.get(k, 0)) - prevu.get(k, 0)
                    s['usage'][model][k] += d
                seen_msg[mid] = {k: max(newu[k], prevu.get(k, 0)) for k in newu}
                for b in m.get('content') or []:
                    if not isinstance(b, dict): continue
                    if b.get('type') == 'text':
                        last_asst_text = b.get('text') or last_asst_text
                        if cur is not None: cur['asst_text_len'] += len(b.get('text') or '')
                    elif b.get('type') == 'tool_use':
                        name = b.get('name') or '?'; inp = b.get('input') or {}
                        s['tools'][name] += 1
                        if cur is not None: cur['after']['tool:' + name] += 1; cur['after']['tools'] += 1
                        if name == 'Bash':
                            cmd = inp.get('command') or ''
                            for mm in BRAIN.finditer(cmd):
                                key = mm.group(1) + ((' ' + mm.group(2)) if mm.group(1) in ('lesson', 'hook', 'todo', 'sessions') and mm.group(2) else '')
                                flags = ''
                                if mm.group(1) == 'add': flags = ' --draft' if '--draft' in cmd else ''
                                test = bool(re.search(r'BRAIN_VAULT|BRAIN_CONFIG|dart run|bin/brain|build/|/tmp/|scratchpad|\$BRAIN|\./brain|assets/brain', cmd))
                                key2 = key + ('' if not test else ' (시험)')
                                s['brain'][key2] += 1
                                if cur is not None: cur['after_brain'].append(key2)
                                if mm.group(1) in ('add', 'lesson', 'write') :
                                    ev = dict(sess=os.path.basename(path)[:8], sub=sub, cwd=s['cwd'], ts=o.get('timestamp'), key=key, test=test, human=(cur or {}).get('i'), cmd=cmd[:160], res='', err=None)
                                    BEV.append(ev); TU[b.get('id')] = ev
                        elif name in ('Agent', 'Task'):
                            st = inp.get('subagent_type') or 'default'; s['agents'][st] += 1
                            if 'verifier' in st: BEV.append(dict(sess=os.path.basename(path)[:8], sub=sub, cwd=s['cwd'], ts=o.get('timestamp'), key='verifier', test=False, human=(cur or {}).get('i'), cmd=(inp.get('prompt') or '')[:160], res='', err=None))
                            s['agent_models'][inp.get('model') or '(지정 없음)'] += 1
                            if cur is not None: cur['after_agents'].append(st)
                        elif name == 'Skill':
                            sk = inp.get('skill') or '?'; s['skills'][sk] += 1
                            if cur is not None: cur['after_skills'].append(sk)
    for k in ('models', 'effort', 'tools', 'brain', 'agents', 'agent_models', 'skills', 'hooks', 'versions', 'entry'): s[k] = dict(s[k])
    s['usage'] = {k: dict(v) for k, v in s['usage'].items()}
    sessions.append(s)
tops = sorted(glob.glob(ROOT + '/*/*.jsonl'), key=os.path.getmtime)
subs = sorted(set(glob.glob(ROOT + '/*/*/**/*.jsonl', recursive=True)))
for f in tops: parse(f)
for f in subs: parse(f, sub=True)
for h in humans: h['after'] = dict(h['after'])
json.dump(sessions, open(OUT + '/sessions.json', 'w'), ensure_ascii=False)
with open(OUT + '/human.jsonl', 'w') as fh:
    for h in humans: fh.write(json.dumps(h, ensure_ascii=False) + '\n')
json.dump(BEV, open(OUT + '/brain_events.json', 'w'), ensure_ascii=False)
print('dup lines skipped', DUP[0], 'brain events', len(BEV))
print('top', len(tops), 'sub', len(subs), 'human msgs', len(humans))
