"""스킬·안내 글을 줄인 뒤에도 동작과 턴 수가 지켜지는지 실제 Claude Code로 잰다 (설계서_프롬프트이후 6.3, 11/14).

돈이 든다(`claude -p`). `--plan`은 무료로 실행 목록만 보여 준다.

  python3 bench/token/skill_bench.py --plan
  python3 bench/token/skill_bench.py --run --out <결과 폴더> [--only pilot] [--budget 3.0]                      # 1차: 평소 말투 11가지
  python3 bench/token/skill_bench.py --run --set skill --models haiku,claude-opus-5-5 --out <결과 폴더> --budget 3.0   # 2차: 스킬을 꼭 읽는 8가지
  python3 bench/token/skill_bench.py --report --out <결과 폴더>

준비물(환경변수):
  BENCH_PLUGINS  플러그인 폴더들이 든 곳: <BENCH_PLUGINS>/v1, /now, /diet (각각 .claude-plugin/plugin.json, skills, hooks, bin/brain)
  BENCH_VAULT    지금 구조(구역) 지식 폴더 사본 — now·diet가 쓴다
  BENCH_VAULT_V1 프롬프트 전 구조 지식 폴더 사본 — v1이 쓴다
K4·K5(지난 세션 정리)는 이 맥의 실제 지난 세션 2개를 읽는다(다른 맥에서는 SKILL_SET의 session id를 바꾼다).
큰 모델은 비싸다: 실행마다 맥락 약 3만 토큰을 캐시에 새로 써서 Opus 5.5는 한 번에 0.2~1달러였다(11/14, Haiku는 0.006~0.1달러).
실제 지식 폴더는 건드리지 않는다: 실행마다 사본을 새로 복사해 쓰고, 끝나면 사본과 그 색인 캐시를 지운다.
세션 기록은 남기지 않는다(--no-session-persistence): 사용자 앱의 "지난 세션" 목록에 시험 세션이 끼지 않게.
"""
import argparse, concurrent.futures, hashlib, json, os, re, shutil, subprocess, sys, threading, time

FIND_SUFFIX = ' 근거 노트 id를 적어 줘.'

# kind: find(정답 id가 답에 있나) · none(없다고 하나) · build(만들기 요청: 노트를 근거로 제안하나)
#       save(새 초안 1개, 주제) · changed(옛 노트를 고쳤나) · auto(시키지 않아도 저장하나) · pref(노트가 아니라 실수 노트로)
SCENARIOS = [
    dict(id='F1', kind='find', expect='n_0046', v1=True, prompt='카카오톡 봇 이벤트 받는 방식 뭘로 하기로 했었지? 짧게 답해 줘.' + FIND_SUFFIX),
    dict(id='F2', kind='find', expect='n_0038', v1=True, prompt='Isolate.run에 클로저 넘겼다가 났던 오류 뭐였지? 어떻게 고쳤더라 짧게 답해 줘.' + FIND_SUFFIX),
    dict(id='F3', kind='find', expect='n_0014', v1=True, prompt='앱에서 claude -p 돌릴 때 --bare 옵션 써도 됐었나? 짧게 답해 줘.' + FIND_SUFFIX),
    dict(id='F4', kind='find', expect='n_0045', v1=True, prompt='한반도감 작품 제작 리포트에 적은 팀명이 뭐였지? 짧게 답해 줘.' + FIND_SUFFIX),
    dict(id='F5', kind='none', v1=True, prompt='주식 배당 투자 전략 정리해 둔 거 있었나? 짧게 답해 줘.' + FIND_SUFFIX),
    dict(id='B1', kind='build', expect='n_0010', v1=True,
         prompt='다른 앱이 어떻게 만들어졌는지 뜯어보고 똑같이 따라 만드는 도구를 만들고 싶어. 어떻게 시작하면 좋을지 먼저 알려 줘.'),
    dict(id='S1', kind='save', topic='개발 지식/Flutter', v1=True,
         prompt='Flutter에서 긴 ListView 스크롤이 버벅이던 건 itemExtent를 안 줘서였어. itemExtent: 56을 주니까 1만 줄에서 '
                '프레임 시간이 18ms에서 6ms로 줄어든 걸 방금 프로파일로 확인했어. 다른 앱에서도 쓸 거니까 이거 세컨드 브레인에 저장해 줘.'),
    dict(id='S2', kind='save', topic='개발 지식/', v1=False,
         prompt='Docker 이미지 빌드가 매번 3분씩 걸리던 원인을 찾았어. Dockerfile에서 COPY . . 이 의존성 설치보다 앞에 있어서 '
                '코드만 바꿔도 캐시가 깨졌던 거야. package.json만 먼저 복사하고 설치한 다음 나머지를 복사하니 40초로 줄었어(확인함). '
                '다른 프로젝트에서도 쓸 지식이니까 세컨드 브레인에 저장해 줘.'),
    dict(id='S3', kind='changed', note='n_0002', must='whisper', v1=False,
         prompt='회의록 앱 경량 구성에서 받아쓰기 방식을 바꾸기로 확정했어. Apple 내장 SpeechAnalyzer 대신 whisper.cpp tiny 모델을 쓴다. '
                '이유는 SpeechAnalyzer가 내 맥 macOS 버전에서 안 돌아서야(직접 실행해 보고 확인). 세컨드 브레인에 반영해 줘.'),
    dict(id='S4', kind='auto', v1=True,
         prompt='방금 직접 재 봤는데 Astro 홍보 페이지 빌드가 느렸던 건 이미지 최적화 때문이 맞았어. astro.config의 이미지 서비스를 '
                'sharp에서 passthrough로 바꾸니 빌드가 90초에서 12초가 됐어. 그래서 홍보 페이지는 passthrough로 가기로 확정했어. '
                '이제 README 맨 위에 넣을 한 문장짜리 프로젝트 소개만 하나 써 줘.'),
    dict(id='S5', kind='pref', v1=False,
         prompt='앞으로 어떤 프로젝트에서든 표를 만들 때는 숫자 단위를 칸마다 쓰지 말고 머리글에 한 번만 적어 줘. 이건 계속 지켜 줘.'),
]
APP_SAVE = ('brain-save 스킬을 써서 지난 Claude Code 세션 {id} 의 지식을 세컨드 브레인에 초안으로 저장해 줘. '
            '바뀐 결정을 옛 노트에 고칠 때는 brain write에 --source-session {id} 를 붙여 줘. '
            '저장할 것이 없으면 brain sessions mark로 skipped 처리해 줘. brain add에는 heredoc을 바로 붙이고 cat 파이프는 쓰지 마. '
            '끝나면 저장한 노트 id와 제목만 짧게 알려 줘.')  # 앱의 화면 없는 정리와 같은 문장 (lib/core/claude_code.dart saveSession)
_by = {s['id']: s for s in SCENARIOS}
# 스킬을 꼭 읽는 경로 (2차, 11/14): 1차에서 AI가 스킬을 거의 읽지 않아(찾기 0/24, 저장 4/20) 줄인 글의 효과를 볼 수 없었다.
# 스킬 이름을 불러 읽게 하고, 앱의 지난 세션 정리(늘 스킬을 읽는 실제 경로)를 같은 문장으로 돌린다.
SKILL_SET = [
    dict(_by['S1'], id='K1', reps=3, prompt='brain-save 스킬을 써서 저장해 줘. ' + _by['S1']['prompt']),
    dict(_by['S2'], id='K2', reps=3, prompt='brain-save 스킬을 써서 저장해 줘. ' + _by['S2']['prompt']),
    dict(_by['S3'], id='K3', reps=3, prompt='brain-save 스킬을 써서 반영해 줘. ' + _by['S3']['prompt']),
    dict(id='K4', kind='session', session='c050c55e', v1=False, reps=2, prompt=APP_SAVE.format(id='c050c55e')),  # 한 쪽(8,078자)
    dict(id='K5', kind='session', session='72cd4909', v1=False, reps=2, prompt=APP_SAVE.format(id='72cd4909')),  # 두 쪽(23,756자): 이어 읽기
    dict(_by['F2'], id='Q1', reps=2, prompt='second-brain 스킬을 써서 내 노트에서 찾아 줘. ' + _by['F2']['prompt']),
    dict(_by['F5'], id='Q2', reps=2, prompt='second-brain 스킬을 써서 내 노트에서 찾아 줘. ' + _by['F5']['prompt']),
    dict(_by['B1'], id='Q3', reps=2, prompt='second-brain 스킬을 써서 진행해 줘. ' + _by['B1']['prompt']),
]
PILOT = dict(id='P0', kind='pilot', v1=True, prompt='안녕. 한 줄로만 답해 줘.')

lock = threading.Lock()


BIG_V1 = ('K1', 'Q1', 'Q2', 'Q3')  # v1에도 있는 경로 (구역·멈춤이 없던 판이라 K2~K5는 견줄 수 없다)


def plan(reps, arms, sonnet, which='base', models=('haiku',)):
    if which == 'skill':
        runs = []
        for model in models:
            if model == 'haiku':  # 값이 싸서 여러 번: 턴 수는 같은 입력에서도 ±1씩 흔들린다
                runs += [(arm, s, rep, model) for s in SKILL_SET for arm in arms if arm != 'v1' for rep in range(1, s['reps'] + 1)]
                continue
            # 큰 모델은 한 번씩: 스킬 경로 8가지(now·diet) + v1으로 되는 4가지 + 자동 저장(S4, 시키지 않아도 저장하나)
            runs += [(arm, s, 1, model) for s in SKILL_SET for arm in arms if arm != 'v1']
            runs += [('v1', s, 1, model) for s in SKILL_SET if s['id'] in BIG_V1 and 'v1' in arms]
            runs += [(arm, _by['S4'], 1, model) for arm in arms if arm != 'v1']
        return runs
    runs = []
    for arm in arms:
        runs.append((arm, PILOT, 1, 'haiku'))
    for s in SCENARIOS:
        for arm in arms:
            if arm == 'v1':
                if s['v1']: runs.append((arm, s, 1, 'haiku'))
                continue
            for rep in range(1, reps + 1): runs.append((arm, s, rep, 'haiku'))
            if sonnet and s['kind'] in ('save', 'changed', 'auto', 'pref'): runs.append((arm, s, 1, 'sonnet'))
    return runs


def snapshot(vault):
    out = {}
    for sub in ('wiki', 'lessons'):
        for d, _, files in os.walk(os.path.join(vault, sub)):
            for f in files:
                if f.endswith('.md'):
                    path = os.path.join(d, f)
                    out[os.path.relpath(path, vault)] = hashlib.sha1(open(path, 'rb').read()).hexdigest()
    return out


def front(path, key):
    m = re.search(rf'^{key}: *(.*)$', open(path, errors='ignore').read(3000), re.M)
    return m.group(1).strip().strip('"') if m else ''


def judge(s, arm, row, vault, before):
    after = snapshot(vault)
    new_notes = [p for p in after if p not in before and p.startswith('wiki/') and not p.endswith('index.md')]
    new_lessons = [p for p in after if p not in before and p.startswith('lessons/L-')]
    changed = [p for p in after if p in before and after[p] != before[p] and p.startswith('wiki/') and not p.endswith('index.md')]
    row['new_notes'] = [f"{os.path.dirname(p)[5:]} | {front(os.path.join(vault, p), 'status')} | {front(os.path.join(vault, p), 'title')[:40]}" for p in new_notes]
    row['new_lessons'] = len(new_lessons)
    row['changed_notes'] = [front(os.path.join(vault, p), 'id') for p in changed]
    text = row.get('result_full', '')
    kind = s['kind']
    if kind == 'pilot': return True
    drafts_only = all(front(os.path.join(vault, p), 'status') == 'draft' for p in new_notes)
    if kind == 'find': return s['expect'] in text
    if kind == 'none': return bool(re.search(r'없', text))
    if kind == 'build': return s['expect'] in text
    if kind == 'save':
        ok_topic = arm == 'v1' or all(os.path.dirname(p)[5:].startswith(s['topic']) for p in new_notes)
        return len(new_notes) == 1 and drafts_only and ok_topic
    if kind == 'changed':
        hit = [p for p in changed if front(os.path.join(vault, p), 'id') == s['note']]
        fixed = bool(hit) and s['must'] in (front(os.path.join(vault, hit[0]), 'title') + front(os.path.join(vault, hit[0]), 'summary')).lower()
        row['detail'] = '옛 노트 고침' if fixed else ('새 노트만(옛 결정 남음)' if new_notes else '아무것도 안 함')
        return fixed
    if kind == 'auto': return len(new_notes) >= 1 and drafts_only and '세컨드 브레인에 저장' in text
    if kind == 'pref': return len(new_lessons) >= 1 and not new_notes
    if kind == 'session':
        # 끝까지 읽고 저장함·건너뜀으로 닫았나 (다 안 읽고 저장하면 brain이 "일부 저장"으로 적는다)
        status = ''
        for line in open(os.path.join(vault, '_meta', 'sessions.jsonl'), errors='ignore'):
            try: e = json.loads(line)
            except Exception: continue
            if str(e.get('id', '')).startswith(s['session']): status = e.get('status', '')
        row['detail'] = f'세션 표시 {status or "없음"}'
        return status in ('saved', 'skipped') and drafts_only
    return False


def run_one(arm, s, rep, model, out, budget_left):  # budget_left: 이 실행 하나의 최대 비용
    plugins = os.environ['BENCH_PLUGINS']
    source = os.environ['BENCH_VAULT_V1' if arm == 'v1' else 'BENCH_VAULT']
    name = f"{arm}-{s['id']}-{model}-{rep}"
    work = os.path.join(out, 'work', name)
    shutil.rmtree(work, ignore_errors=True)
    vault = os.path.join(work, 'vault'); cwd = os.path.join(work, 'cwd')
    os.makedirs(cwd)
    shutil.copytree(source, vault, symlinks=True)
    config = os.path.join(work, 'config.json')
    json.dump({'vault': vault}, open(config, 'w'))
    before = snapshot(vault)
    env = {k: v for k, v in os.environ.items() if not (k.startswith('CLAUDE') or k.startswith('ANTHROPIC') or k.startswith('BRAIN_'))}
    env.update(BRAIN_VAULT=vault, BRAIN_CONFIG=config, PATH=os.path.join(plugins, arm, 'bin') + os.pathsep + env.get('PATH', ''))
    args = ['claude', '-p', s['prompt'], '--model', model, '--output-format', 'stream-json', '--verbose', '--no-session-persistence',
            '--permission-mode', 'dontAsk', '--allowedTools', 'Bash(brain *)', 'Skill', 'Agent', 'Task',
            '--plugin-dir', os.path.join(plugins, arm),
            '--settings', json.dumps({'enabledPlugins': {'second-brain@second-brain-local': False}}),
            '--max-budget-usd', f'{budget_left:.2f}']
    if s['kind'] == 'session': args += ['--tools', 'Bash,Skill']  # 앱의 화면 없는 정리와 같은 도구
    started = time.time()
    try:
        r = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=900)
        stdout = r.stdout
    except subprocess.TimeoutExpired as e:
        stdout = (e.stdout or b'').decode(errors='ignore') if isinstance(e.stdout, bytes) else (e.stdout or '')
    os.makedirs(os.path.join(out, 'raw'), exist_ok=True)
    open(os.path.join(out, 'raw', name + '.jsonl'), 'w').write(stdout)  # 진단용 원본 (결과 폴더는 저장소 밖)
    # Claude Code가 작업 폴더마다 만드는 ~/.claude/projects/<경로> (메모리·하위 에이전트 정보)도 지운다. 세션 기록(.jsonl)은 없다.
    project = os.path.join(os.path.expanduser('~/.claude/projects'), re.sub(r'[^A-Za-z0-9]', '-', os.path.realpath(cwd)))
    if '-bench-' in project or 'work' in project: shutil.rmtree(project, ignore_errors=True)
    tools, skills, stops, final = [], [], 0, None
    session_hook = 0; parallel = 0; last_msg = None; in_msg = 0; real_model = None; requests = 0
    for line in stdout.splitlines():
        try: ev = json.loads(line)
        except Exception: continue
        if ev.get('type') == 'system' and ev.get('subtype') == 'hook_response' and 'SessionStart' in str(ev.get('hook_event') or ev.get('hook_name') or ''):
            session_hook = len(str(ev.get('output') or ev.get('stdout') or ''))
        if ev.get('type') == 'system' and ev.get('subtype') == 'init': real_model = ev.get('model')
        if ev.get('parent_tool_use_id'):  # 하위 에이전트(검증 에이전트) 안의 호출은 따로 센다
            if ev.get('type') == 'assistant':
                for c in ev.get('message', {}).get('content', []):
                    if c.get('type') == 'tool_use': tools.append('  (sub) ' + str((c.get('input') or {}).get('command') or c['name'])[:60].replace('\n', ' '))
            continue
        if ev.get('type') == 'assistant':
            msg = ev.get('message', {})
            if msg.get('id') != last_msg: last_msg = msg.get('id'); in_msg = 0; requests += 1
            for c in msg.get('content', []):
                if c.get('type') != 'tool_use': continue
                in_msg += 1
                if in_msg == 2: parallel += 1
                inp = c.get('input') or {}
                if c['name'] == 'Skill': skills.append(str(inp.get('skill')))
                tools.append(c['name'] + ':' + str(inp.get('command') or inp.get('skill') or inp.get('subagent_type') or '')[:70].replace('\n', ' '))
        elif ev.get('type') == 'user':
            content = ev.get('message', {}).get('content')
            for c in content if isinstance(content, list) else []:
                if c.get('type') == 'tool_result' and '저장하지 않음' in json.dumps(c.get('content'), ensure_ascii=False): stops += 1
        elif ev.get('type') == 'result':
            final = ev
    row = dict(name=name, arm=arm, scenario=s['id'], kind=s['kind'], model=model, real_model=real_model, rep=rep, seconds=round(time.time() - started))
    if final is None:
        row.update(error=stdout[-400:], ok=False, cost=0)
    else:
        u = final.get('usage', {})
        row.update(input_total=u.get('input_tokens', 0) + u.get('cache_creation_input_tokens', 0) + u.get('cache_read_input_tokens', 0),
                   cache_write=u.get('cache_creation_input_tokens', 0), cache_read=u.get('cache_read_input_tokens', 0),
                   output=u.get('output_tokens', 0), turns=final.get('num_turns'), cost=final.get('total_cost_usd') or 0,
                   tools=tools, skills=skills, stops=stops, parallel_turns=parallel, requests=requests, session_hook_chars=session_hook,
                   result_full=final.get('result') or '', subtype=final.get('subtype'))
        row['ok'] = bool(judge(s, arm, row, vault, before)) and final.get('subtype') == 'success'  # 예산에 걸려 끊긴 실행은 맞음이 아니다
        row['result'] = row.pop('result_full')[:500].replace('\n', ' ')
    with lock:
        with open(os.path.join(out, 'results.jsonl'), 'a') as f: f.write(json.dumps(row, ensure_ascii=False) + '\n')
    # 사본과 그 색인 캐시(~/Library/Caches/com.konga22.secondbrain/<경로 sha1 앞 12자>)를 지운다. 이 실행이 만든 것만.
    cache = os.path.join(os.path.expanduser('~/Library/Caches/com.konga22.secondbrain'), hashlib.sha1(vault.encode()).hexdigest()[:12])
    shutil.rmtree(cache, ignore_errors=True)
    shutil.rmtree(work, ignore_errors=True)
    return row


def report(out):
    rows = [json.loads(l) for l in open(os.path.join(out, 'results.jsonl'))]
    rows = [r for r in rows if r['kind'] != 'pilot' and 'error' not in r and r.get('subtype', 'success') == 'success']
    def count_requests(r):  # 옛 결과 줄에는 요청 수가 없다: 보관한 원본 출력에서 센다
        raw = os.path.join(out, 'raw', r['name'] + '.jsonl')
        if not os.path.exists(raw): return None
        ids = set()
        for line in open(raw, errors='ignore'):
            try: ev = json.loads(line)
            except Exception: continue
            if ev.get('type') == 'assistant' and not ev.get('parent_tool_use_id'): ids.add(ev.get('message', {}).get('id'))
        return len(ids)
    for r in rows: r['requests'] = r.get('requests') or count_requests(r)
    for r in rows: r['turns'] = r.get('requests') or r['turns']  # 요청 수(API 호출)로 견준다. num_turns는 도구 호출을 따로 세어 함께 부른 호출을 못 가린다
    groups = {'찾기': ('find', 'none', 'build'), '저장': ('save', 'changed', 'auto', 'pref'), '지난 세션 정리': ('session',)}
    print(f"실행 {len(rows)}번, 비용 합계 ${sum(r['cost'] for r in rows):.2f}")
    for model in sorted({r['model'] for r in rows}):
        for label, kinds in groups.items():
            print(f'\n[{model}] {label}')
            print('판 | 실행 | 맞음 | 평균 입력 토큰 | 평균 출력 토큰 | 평균 요청 수 | 스킬 읽음 | 멈춤 | 평균 비용')
            for arm in ('v1', 'now', 'diet'):
                sel = [r for r in rows if r['arm'] == arm and r['model'] == model and r['kind'] in kinds]
                if not sel: continue
                n = len(sel); avg = lambda k: sum(r[k] for r in sel) / n
                print(f"{arm} | {n} | {sum(r['ok'] for r in sel)}/{n} | {avg('input_total'):,.0f} | {avg('output'):,.0f} | {sum(r.get('requests') or r['turns'] for r in sel) / n:.2f} | "
                      f"{sum(bool(r['skills']) for r in sel)}/{n} | {sum(r['stops'] for r in sel)} | ${avg('cost'):.4f}")
    for model in sorted({r['model'] for r in rows}):
        print(f'\n[{model}] 시나리오별: 맞음 · 평균 요청 수 · 평균 입력 토큰 · 스킬 읽음')
        for s in SCENARIOS + SKILL_SET:
            cells = []
            for arm in ('v1', 'now', 'diet'):
                sel = [r for r in rows if r['arm'] == arm and r['scenario'] == s['id'] and r['model'] == model]
                cells.append('-' if not sel else f"{sum(r['ok'] for r in sel)}/{len(sel)} · {sum(r['turns'] for r in sel)/len(sel):.1f}번 · "
                             f"{sum(r['input_total'] for r in sel)/len(sel):,.0f} · {sum(bool(r['skills']) for r in sel)}/{len(sel)}")
            if any(c != '-' for c in cells): print(f"{s['id']} {s['kind']:8} | v1 {cells[0]} | now {cells[1]} | diet {cells[2]}")
        # 짝 비교: 같은 시나리오·차례끼리 diet − now. 스킬을 읽은 쌍만 따로도 센다(줄인 글이 실제로 맥락에 들어간 실행).
        import random
        for label, need_skill in (('모든 쌍', False), ('두 판 모두 스킬을 읽은 쌍', True)):
            pairs = []
            for r in rows:
                if r['arm'] != 'diet' or r['model'] != model: continue
                other = [o for o in rows if o['arm'] == 'now' and (o['scenario'], o['model'], o['rep']) == (r['scenario'], r['model'], r['rep'])]
                if not other or (need_skill and not (r['skills'] and other[0]['skills'])): continue
                pairs.append((r['input_total'] - other[0]['input_total'], r['turns'] - other[0]['turns'], r['cost'] - other[0]['cost'], int(r['ok']) - int(other[0]['ok'])))
            if not pairs: continue
            random.seed(1)
            diffs = [p[0] for p in pairs]
            boots = sorted(sum(random.choice(diffs) for _ in diffs) / len(diffs) for _ in range(5000))
            print(f"짝 비교 diet − now, {label} {len(pairs)}쌍: 입력 토큰 평균 {sum(diffs)/len(diffs):+,.0f} (95% {boots[125]:+,.0f} ~ {boots[4875]:+,.0f}), "
                  f"요청 수 평균 {sum(p[1] for p in pairs)/len(pairs):+.2f} (늘어난 쌍 {sum(p[1] > 0 for p in pairs)} · 줄어든 쌍 {sum(p[1] < 0 for p in pairs)}), "
                  f"비용 평균 {sum(p[2] for p in pairs)/len(pairs):+.4f}달러, 맞음 {sum(p[3] for p in pairs):+d}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--plan', action='store_true'); ap.add_argument('--run', action='store_true'); ap.add_argument('--report', action='store_true')
    ap.add_argument('--out'); ap.add_argument('--only', help='pilot | 시나리오 id 쉼표 목록'); ap.add_argument('--arms', default='v1,now,diet')
    ap.add_argument('--reps', type=int, default=2); ap.add_argument('--sonnet', action='store_true', help='저장 시나리오를 Sonnet으로 한 번씩 더')
    ap.add_argument('--models', default='haiku', help="--set skill에서 돌릴 모델, 쉼표로 (예: haiku,claude-opus-5-5,claude-sonnet-5-5)")
    ap.add_argument('--set', default='base', help='base(1차) | skill(스킬을 꼭 읽는 경로)')
    ap.add_argument('--budget', type=float, default=3.0, help='비용 합계가 이 값을 넘으면 남은 실행을 멈춘다')
    a = ap.parse_args()
    runs = plan(a.reps, a.arms.split(','), a.sonnet, a.set, a.models.split(','))
    if a.only == 'pilot': runs = [r for r in runs if r[1]['kind'] == 'pilot']
    elif a.only: runs = [r for r in runs if r[1]['id'] in a.only.split(',')]
    else: runs = [r for r in runs if r[1]['kind'] != 'pilot']
    if a.plan or not (a.run or a.report):
        for arm, s, rep, model in runs: print(arm, s['id'], s['kind'], model, rep)
        print(f'모두 {len(runs)}번')
        return
    if a.report: return report(a.out)
    os.makedirs(a.out, exist_ok=True)
    done = set()
    path = os.path.join(a.out, 'results.jsonl')
    if os.path.exists(path): done = {json.loads(l)['name'] for l in open(path) if 'error' not in json.loads(l)}
    spent = [0.0]; reserved = [0.0]
    # 판마다 한 줄로(같은 판은 차례대로 — 프롬프트 캐시가 이어진다), 판끼리는 함께 돌린다.
    def lane(arm):
        for r_arm, s, rep, model in runs:
            if r_arm != arm or f"{arm}-{s['id']}-{model}-{rep}" in done: continue
            cap = 0.5 if model == 'haiku' else 1.0
            with lock:
                if spent[0] + reserved[0] + cap > a.budget:
                    print(f'비용 한도 ${a.budget}에 닿을 수 있어 멈춤 (쓴 것 ${spent[0]:.2f}, 돌고 있는 실행 몫 ${reserved[0]:.2f})'); return
                reserved[0] += cap
            row = run_one(arm, s, rep, model, a.out, cap)
            with lock:
                reserved[0] -= cap
                spent[0] += row.get('cost') or 0
                print(f"{row['name']}: {'O' if row.get('ok') else 'X'} 턴 {row.get('turns')} 입력 {row.get('input_total')} ${row.get('cost', 0):.4f} (합계 ${spent[0]:.2f})", flush=True)
    with concurrent.futures.ThreadPoolExecutor(3) as pool:
        list(pool.map(lane, a.arms.split(',')))


if __name__ == '__main__':
    main()
