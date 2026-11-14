"""목차 먼저 보여 주기(설계서_프롬프트이후 5.11)의 기존 대비 차이를 잰다 (11/14).

돈 안 드는 것 (AI를 부르지 않는다):
  python3 bench/toc/toc_bench.py replay --base <기존 brain> --new <새 brain> --vault <지식 폴더 사본>
      이 맥의 지난 사용자 요청을 세션 순서대로 두 판의 요청 훅에 넣어, 목차가 붙는 세션·요청 수와 글자 수를 견준다.
      만들기 요청이 아닌 요청에서 두 판의 훅 글이 글자 하나까지 같은지도 본다. 요청 내용은 출력하지 않는다.
  python3 bench/toc/toc_bench.py recall --base <기존 brain> --new <새 brain> --vault <지식 폴더 사본>
      질문 30문(bench/questions.yaml)과 평소 말투 질문(questions_casual.yaml)의 찾기 정확도가 그대로인지.

돈 드는 것 (`claude -p`, 사용자 승인 뒤에만):
  python3 bench/toc/toc_bench.py live --plugins <폴더> --vault <사본> --scenario <시나리오.json> --out <결과 폴더> --plan
  python3 bench/toc/toc_bench.py live … --run --cells then:base,then:new --models claude-opus-5-5 --reps 4 --budget 8
  python3 bench/toc/toc_bench.py report --out <결과 폴더>

준비물:
  <기존 brain>·<새 brain>: `dart build cli`로 만든 실행 파일 (bundle/bin/brain, 옆 lib/libsqlite3.dylib 필요).
      기존 = 목차를 넣기 전 커밋, 새 = 지금 코드. 같은 실행 파일에 BRAIN_LEGACY=toc를 줘도 기존 판이 된다.
  --plugins: <폴더>/base, <폴더>/new 에 플러그인 한 벌씩(.claude-plugin/plugin.json, hooks/hooks.json, skills, agents, bin/brain, lib/).
  --scenario: {"cwd_name": "…", "turns": ["첫 요청", "둘째 요청"], "files": {"2": {"파일 이름": "내용"}}, "target": "n_0086", "method_tag": "작업방식"}
      사용자 문장과 화면 내용이 들어 있어 저장소 밖에 둔다. `files`는 그 턴 직전에 작업 폴더에 넣을 파일이다 —
      화면 내용을 요청 글에 붙이면 요청 훅이 그 글의 낱말로 노트를 붙여 원래 세션(그림만 붙임)보다 쉬운 조건이 된다.
칸(cells)은 `<지식 폴더 상태>:<플러그인>`이다. 플러그인은 --plugins 아래 폴더 이름(`base` 기존, `new` 새 판, `new2` 안내 보강판). 지식 폴더 상태:
  `then`  문제의 세션 때와 같은 상태 — 작업 방식 노트의 태그를 빼고, 그 실패 뒤에 생긴 실수 노트(scenario의 later_lessons)를 보관으로 돌린다.
          태그도 규칙도 없는 보통 노트를 목차만으로 알아보는지 본다.
  `now`   사본 그대로 — 태그가 있어 기존 판도 훅이 그 노트를 붙이고, 실패 뒤 생긴 규칙 문장도 세션 시작 목록에 있다.
  `notag` 태그만 뺀다(규칙 문장은 남음). 첫 본 실행에서 규칙 문장만으로 기존 판이 노트를 찾아 `then`을 따로 두었다.
실제 지식 폴더·실제 작업 폴더는 건드리지 않는다: 실행마다 사본을 새로 복사하고, 끝나면 사본·색인 캐시·세션 기록을 지운다.
"""
import argparse, glob, hashlib, json, os, re, shutil, subprocess, sys, time, uuid

HOME = os.path.expanduser('~')
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOC_MARK = '세컨드 브레인 목차 —'
ABOVE_MARK = '목차는 이 대화 앞쪽'
SYSTEM = re.compile(r'<task-notification>|\[SYSTEM NOTIFICATION|^\s*<system-reminder|\[Subagent hand-back\]|<agent-message ')
CONTINUED = 'This session is being continued from a previous conversation'


def clean_env(vault, extra=None):
    """Claude Code 세션 안에서 돌려도 그 세션을 타지 않게 CLAUDE*·BRAIN_*를 비운다 (n_0093)."""
    env = {k: v for k, v in os.environ.items() if not (k.startswith('CLAUDE') or k.startswith('ANTHROPIC') or k.startswith('BRAIN_'))}
    cfg = vault.rstrip('/') + '-config.json'
    if not os.path.exists(cfg):
        json.dump({'vault': vault}, open(cfg, 'w'))
    env.update(BRAIN_VAULT=vault, BRAIN_CONFIG=cfg, CLAUDECODE='', CLAUDE_CODE_SESSION_ID='', BRAIN_LEGACY='')
    env.update(extra or {})
    return env


def brain(binary, vault, *args, stdin=None, extra=None):
    r = subprocess.run([binary, *args], input=stdin, capture_output=True, text=True, env=clean_env(vault, extra))
    return r.stdout


def index_cache(vault):
    return os.path.join(HOME, 'Library/Caches/com.konga22.secondbrain', hashlib.sha1(vault.encode()).hexdigest()[:12])


def copy_vault(source, dest):
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(source, dest, symlinks=True)
    return dest


def drop(vault):
    shutil.rmtree(index_cache(vault), ignore_errors=True)
    shutil.rmtree(vault, ignore_errors=True)
    cfg = vault.rstrip('/') + '-config.json'
    if os.path.exists(cfg):
        os.remove(cfg)


# ---------- 무료: 지난 요청 다시 넣기 ----------

def sessions():
    """세션 파일마다 (id, [사람 요청 또는 ('compact',)]) — 하위 에이전트·시험 폴더는 뺀다.
    세션을 이어 열면 앞 기록이 새 파일에 복사된다: 같은 줄(uuid)은 처음 나온 파일에서 한 번만 센다."""
    seen = set()
    for f in sorted(glob.glob(os.path.join(HOME, '.claude/projects/*/*.jsonl')), key=os.path.getmtime):
        if 'scratchpad' in f or 'bench' in f:
            continue
        items = []
        for line in open(f, errors='ignore'):
            if '"type":"user"' not in line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if ev.get('type') != 'user' or ev.get('isMeta') or ev.get('isSidechain'):
                continue
            c = (ev.get('message') or {}).get('content')
            if isinstance(c, list):
                if any(isinstance(p, dict) and p.get('type') == 'tool_result' for p in c):
                    continue
                c = '\n'.join(p.get('text', '') for p in c if isinstance(p, dict) and p.get('type') == 'text')
            if not isinstance(c, str) or not c.strip():
                continue
            key = ev.get('uuid') or c[:80]
            if key in seen:
                continue
            seen.add(key)
            if ev.get('isCompactSummary') or CONTINUED in c[:400]:
                items.append(('compact',))  # 압축: 훅은 이 글에 돌지 않고, 세션 시작 훅이 source=compact로 돈다
                continue
            if c.startswith('<command-') or c.startswith('<local-command') or c.startswith('Base directory for this skill') or SYSTEM.search(c):
                continue
            items.append(('prompt', c))
        if items:
            yield os.path.basename(f)[:-6], items


def hook_text(binary, vault, prompt, session, extra=None):
    out = brain(binary, vault, 'hook', 'prompt', stdin=json.dumps({'prompt': prompt, 'cwd': '/tmp/replay', 'session_id': session}), extra=extra)
    try:
        return json.loads(out)['hookSpecificOutput']['additionalContext']
    except Exception:
        return ''


def replay(a):
    work = os.path.join(a.work, 'replay')
    os.makedirs(work, exist_ok=True)
    arms = {'base': (a.base, copy_vault(a.vault, os.path.join(work, 'vault-base'))), 'new': (a.new, copy_vault(a.vault, os.path.join(work, 'vault-new')))}
    legacy_vault = copy_vault(a.vault, os.path.join(work, 'vault-legacy'))  # 새 실행 파일 + 이전 방식 스위치 = 기존 판과 같아야 한다
    stat = {k: dict(prompts=0, injected=0, chars=0, toc=0, toc_chars=0, above=0, sessions_toc=set(), per_session={}) for k in arms}
    same_nonbuild = diff_nonbuild = build = legacy_diff = 0
    n_sessions = 0
    try:
        for sid, items in sessions():
            n_sessions += 1
            for item in items:
                if item[0] == 'compact':
                    for arm, (binary, vault) in arms.items():
                        brain(binary, vault, 'hook', 'session-start', stdin=json.dumps({'cwd': '/tmp/replay', 'session_id': sid, 'source': 'compact'}))
                    continue
                texts = {}
                for arm, (binary, vault) in arms.items():
                    t = hook_text(binary, vault, item[1], sid)
                    texts[arm] = t
                    s = stat[arm]
                    s['prompts'] += 1
                    s['injected'] += bool(t)
                    s['chars'] += len(t)
                    s['per_session'][sid] = s['per_session'].get(sid, 0) + len(t)
                    if TOC_MARK in t:
                        s['toc'] += 1
                        s['toc_chars'] += len(t) - t.index(TOC_MARK)
                        s['sessions_toc'].add(sid)
                    if ABOVE_MARK in t:
                        s['above'] += 1
                legacy_diff += hook_text(a.new, legacy_vault, item[1], sid, extra={'BRAIN_LEGACY': 'toc'}) != texts['base']
                if '만들기 요청이다' in texts['base']:
                    build += 1
                elif texts['base'] == texts['new']:
                    same_nonbuild += 1
                else:
                    diff_nonbuild += 1
    finally:
        for _, vault in arms.values():
            drop(vault)
        drop(legacy_vault)
    print(f'세션 {n_sessions}개, 사람 요청 {stat["base"]["prompts"]}개 (압축 이어받기 요약은 요청이 아니라 뺌)')
    print('판 | 훅이 글을 넣은 요청 | 훅 글 합계 | 목차가 붙은 요청 | 목차가 붙은 세션 | 목차 글자 합계 | "앞쪽에 있다" 한 줄 | 가장 많이 쌓인 세션')
    for arm in ('base', 'new'):
        s = stat[arm]
        print(f"{'기존' if arm == 'base' else '새 판'} | {s['injected']} | {s['chars']:,}자 | {s['toc']} | {len(s['sessions_toc'])} | {s['toc_chars']:,}자 | {s['above']} | {max(s['per_session'].values()):,}자")
    print(f'이전 방식 스위치(BRAIN_LEGACY=toc)를 켠 새 실행 파일의 훅 글이 기존 판과 다른 요청: {legacy_diff}개 (0이어야 한다)')
    print(f'만들기 요청 {build}개 · 그 밖 요청 {same_nonbuild + diff_nonbuild}개 가운데 두 판의 훅 글이 같은 것 {same_nonbuild}개, 다른 것 {diff_nonbuild}개')
    if stat['new']['toc']:
        print(f"요청마다 목차를 붙였다면 {build}번 · 약 {build * stat['new']['toc_chars'] // stat['new']['toc']:,}자, 세션에 한 번이라 {stat['new']['toc']}번 · {stat['new']['toc_chars']:,}자")


# ---------- 무료: 찾기 정확도 ----------

def yaml_questions(path):
    qs, cur = [], None
    for line in open(path):
        if line.startswith('- q:'):
            cur = {'q': line[4:].strip().strip('"')}
            qs.append(cur)
        elif cur is not None and ':' in line and not line.lstrip().startswith('#'):
            k, v = line.strip().split(':', 1)
            if k == 'expect':
                cur['expect'] = re.findall(r'n_\d+', v)
    return qs


def recall(a):
    work = os.path.join(a.work, 'recall')
    os.makedirs(work, exist_ok=True)
    try:
        for label, binary in (('기존', a.base), ('새 판', a.new)):
            vault = copy_vault(a.vault, os.path.join(work, 'vault'))
            for name in ('questions.yaml', 'questions_casual.yaml'):
                qs = yaml_questions(os.path.join(REPO, 'bench', name))
                hit = top1 = n = none_ok = none_n = hinted = 0
                for q in qs:
                    out = brain(binary, vault, 'find', q['q'])
                    ids = re.findall(r'^(n_\d{4})  ', out, re.M)
                    hinted += 'brain toc' in out
                    if not q.get('expect'):
                        none_n += 1
                        none_ok += not ids
                        continue
                    n += 1
                    hit += any(e in ids for e in q['expect'])
                    top1 += bool(ids) and ids[0] in q['expect']
                print(f'{label} {name}: 5위 안 {hit}/{n}, 1위 {top1}/{n}, 답 없는 질문에 아무것도 안 냄 {none_ok}/{none_n}, 빈손 안내(brain toc)가 붙은 질문 {hinted}')
            drop(vault)
    finally:
        shutil.rmtree(work, ignore_errors=True)


# ---------- 유료: 실제 Claude Code ----------

# 실행 하나(두 턴 합계)의 비용 상한. 넘으면 그 실행이 끊긴다 — 끊긴 실행도 그때까지 부른 도구는 남는다.
ARMS = {'base': '기존', 'new': '새 판', 'new2': '새 판(안내 보강)'}  # 플러그인 폴더 이름. new2 = 11/14 재현 실험 뒤 "일하는 방식 노트" 문장을 더한 판
VARIANTS = {'then': '그때 상태', 'now': '지금 상태', 'tag': '지금 상태', 'notag': '태그만 뺌'}
CAPS = {'haiku': 0.25, 'claude-haiku-5-5': 0.25, 'claude-sonnet-5-5': 0.5, 'claude-opus-5-5': 0.9, 'claude-fable-5-2': 1.5}
# 웹 검색은 뺐다: 원래 세션에서 웹 검색은 세컨드 브레인을 찾은 뒤의 일이고, 넣으면 실행마다 비용·시간이 크게 는다.
ALLOWED = ['Bash(brain *)', 'Bash(ls *)', 'Skill', 'Read', 'Write', 'Edit', 'Glob', 'Grep']


def strip_tag(vault, note_id, tag):
    """노트 머리말의 tags에서 [tag]만 뺀다 (태그 없는 보통 노트 조건)."""
    for d, _, files in os.walk(os.path.join(vault, 'wiki')):
        for f in files:
            if not f.endswith('.md'):
                continue
            path = os.path.join(d, f)
            text = open(path, encoding='utf-8').read()
            if not re.search(rf'^id: {note_id}$', text[:400], re.M):
                continue
            m = re.search(r'^tags: \[(.*)\]$', text, re.M)
            if not m:
                return False
            kept = [t for t in re.findall(r'"([^"]*)"', m.group(1)) if t != tag]
            new = 'tags: [' + ', '.join(f'"{t}"' for t in kept) + ']'
            open(path, 'w', encoding='utf-8').write(text[:m.start()] + new + text[m.end():])
            return True
    return False


def archive_lesson(vault, lesson_id):
    """실수 노트를 보관으로 돌린다 (세션 시작 목록과 요청 훅에서 빠진다). 사본에서만 쓴다."""
    path = os.path.join(vault, 'lessons', lesson_id + '.md')
    if not os.path.exists(path):
        return False
    text = open(path, encoding='utf-8').read()
    new = re.sub(r'^status: active$', 'status: archived', text, count=1, flags=re.M)
    open(path, 'w', encoding='utf-8').write(new)
    return new != text


def parse_stream(stdout):
    """stream-json에서 메인 대화의 도구 호출·마지막 답·사용량·훅이 넣은 글 길이를 뽑는다."""
    tools, final, hook_chars, toc_in_hook, model = [], None, 0, False, None
    for line in stdout.splitlines():
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get('type') == 'system' and ev.get('subtype') == 'init':
            model = ev.get('model')
        if ev.get('type') == 'system' and ev.get('subtype') == 'hook_response' and 'UserPromptSubmit' in str(ev.get('hook_event') or ev.get('hook_name') or ''):
            text = str(ev.get('output') or ev.get('stdout') or '')
            hook_chars += len(text)
            toc_in_hook = toc_in_hook or TOC_MARK in text or '\\uc138\\ucee8\\ub4dc \\ube0c\\ub808\\uc778 \\ubaa9\\ucc28' in text
        if ev.get('parent_tool_use_id'):
            continue
        if ev.get('type') == 'assistant':
            for c in ev.get('message', {}).get('content', []):
                if c.get('type') == 'tool_use':
                    inp = c.get('input') or {}
                    arg = inp.get('command') or inp.get('skill') or inp.get('file_path') or inp.get('query') or inp.get('url') or ''
                    tools.append(f"{c['name']}:{str(arg)[:160]}".replace('\n', ' '))
        elif ev.get('type') == 'result':
            final = ev
    return tools, final, hook_chars, toc_in_hook, model


def run_live(a, cell, model, rep, cap, scenario):
    variant, arm = cell.split(':')
    name = f'{variant}-{arm}-{model}-{rep}'
    work = os.path.join(a.out, 'work', name)
    shutil.rmtree(work, ignore_errors=True)
    cwd = os.path.join(work, scenario['cwd_name'])
    os.makedirs(cwd)
    vault = copy_vault(a.vault, os.path.join(work, 'vault'))
    plugin = os.path.join(a.plugins, arm)
    if variant in ('notag', 'then'):
        assert strip_tag(vault, scenario['target'], scenario.get('method_tag', '작업방식')), '태그를 뺄 노트를 못 찾음'
    if variant == 'then':
        for lesson in scenario.get('later_lessons', []):
            assert archive_lesson(vault, lesson), f'{lesson}을 보관으로 못 돌림'
    env = clean_env(vault, {'PATH': os.path.join(plugin, 'bin') + os.pathsep + os.environ.get('PATH', '')})
    env.pop('CLAUDECODE', None)
    env.pop('CLAUDE_CODE_SESSION_ID', None)
    subprocess.run([os.path.join(plugin, 'bin', 'brain'), 'index'], capture_output=True, env=env)  # 태그를 뺀 뒤 색인을 맞춘다
    session = str(uuid.uuid4())
    row = dict(name=name, variant=variant, arm=arm, model=model, rep=rep, session=session, turns=[])
    started = time.time()
    spent = 0.0
    os.makedirs(os.path.join(a.out, 'raw'), exist_ok=True)
    for i, text in enumerate(scenario['turns']):
        for rel, content in (scenario.get('files') or {}).get(str(i + 1), {}).items():
            with open(os.path.join(cwd, rel), 'w', encoding='utf-8') as f:
                f.write(content)
        left = cap - spent
        if left < 0.05:
            row['turns'].append(dict(skipped='비용 상한'))
            break
        args = ['claude', '-p', text, '--model', model, '--output-format', 'stream-json', '--verbose',
                '--permission-mode', 'dontAsk', '--allowedTools', *ALLOWED, '--plugin-dir', plugin, '--strict-mcp-config',
                '--settings', json.dumps({'enabledPlugins': {'second-brain@second-brain-local': False}}),
                '--max-budget-usd', f'{left:.2f}']
        args += ['--session-id', session] if i == 0 else ['--resume', session]
        try:
            r = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=1500)
            stdout = r.stdout
        except subprocess.TimeoutExpired as e:
            stdout = e.stdout.decode(errors='ignore') if isinstance(e.stdout, bytes) else (e.stdout or '')
        open(os.path.join(a.out, 'raw', f'{name}-t{i + 1}.jsonl'), 'w').write(stdout)
        tools, final, hook_chars, toc_in_hook, real_model = parse_stream(stdout)
        turn = dict(tools=tools, hook_chars=hook_chars, toc_in_hook=toc_in_hook, model=real_model)
        if final is None:
            turn['error'] = stdout[-300:]
        else:
            u = final.get('usage', {})
            turn.update(cost=final.get('total_cost_usd') or 0, subtype=final.get('subtype'), requests=final.get('num_turns'),
                        input_total=u.get('input_tokens', 0) + u.get('cache_creation_input_tokens', 0) + u.get('cache_read_input_tokens', 0),
                        output=u.get('output_tokens', 0), answer=final.get('result') or '')
            spent += turn['cost']
        row['turns'].append(turn)
    row.update(cost=spent, seconds=round(time.time() - started))
    # 요청 훅의 글은 stream-json에 나오지 않는다. 새 판이 목차를 붙였는지는 훅이 남기는 "붙인 세션" 기록으로 확인한다.
    row['toc_marked'] = os.path.exists(os.path.join(index_cache(vault), 'toc-shown', session))
    # 사본에 생긴 변화(새 노트·실수 노트)와 작업 폴더에 쓴 파일
    row['files_written'] = sorted(os.path.relpath(os.path.join(d, f), cwd) for d, _, fs in os.walk(cwd) for f in fs)
    os.makedirs(os.path.join(a.out, 'answers'), exist_ok=True)
    with open(os.path.join(a.out, 'answers', name + '.md'), 'w') as f:  # 판정용 (저장소 밖)
        for i, t in enumerate(row['turns']):
            f.write(f"## 턴 {i + 1} — 도구 {len(t.get('tools', []))}번, 훅 {t.get('hook_chars')}자, 목차 {'있음' if t.get('toc_in_hook') else '없음'}\n\n")
            f.write('\n'.join('- ' + x for x in t.get('tools', [])) + '\n\n' + (t.get('answer') or t.get('error') or '') + '\n\n')
        for rel in row['files_written']:
            path = os.path.join(cwd, rel)
            if rel.endswith('.md') and os.path.getsize(path) < 200_000:
                f.write(f'## 쓴 파일 {rel} (앞 3,000자)\n\n' + open(path, errors='ignore').read()[:3000] + '\n\n')
    for t in row['turns']:
        t.pop('answer', None)
    with open(os.path.join(a.out, 'results.jsonl'), 'a') as f:
        f.write(json.dumps(row, ensure_ascii=False) + '\n')
    # 뒷정리: 세션 기록(~/.claude/projects/<작업 폴더>)·사본·색인 캐시. 이 실행이 만든 것만.
    slug = lambda path: re.sub(r'[^A-Za-z0-9]', '-', os.path.realpath(path))
    project = os.path.join(HOME, '.claude/projects', slug(cwd))
    if slug(cwd).startswith(slug(a.out) + '-work-') and os.path.isdir(project):
        shutil.rmtree(project, ignore_errors=True)
    drop(vault)
    shutil.rmtree(work, ignore_errors=True)
    return row


def facts(row, target):
    tools = [x for t in row['turns'] for x in t.get('tools', [])]
    brain_calls = [x[5:] for x in tools if x.startswith('Bash:brain ')]
    shows = sorted({m for x in brain_calls for m in re.findall(r'show (n_\d{4})', x)})
    return dict(
        opened=target in shows, shows=shows,
        finds=sum(x.startswith('brain find') for x in brain_calls), tocs=sum(x.startswith('brain toc') for x in brain_calls),
        skill=any(x.startswith('Skill:') and 'second-brain' in x for x in tools),
        web=sum(x.startswith('WebSearch:') or x.startswith('WebFetch:') for x in tools),
        wrote=[f for f in row.get('files_written', []) if f.endswith('.md')],
        toc_turns=[i + 1 for i, t in enumerate(row['turns']) if t.get('toc_in_hook')],
        input_total=sum(t.get('input_total', 0) for t in row['turns']), requests=sum(t.get('requests') or 0 for t in row['turns']),
        cut=any(t.get('subtype') not in (None, 'success') or 'skipped' in t or 'error' in t for t in row['turns']),
    )


def report(a):
    rows = [json.loads(l) for l in open(os.path.join(a.out, 'results.jsonl'))]
    target = json.load(open(a.scenario))['target'] if a.scenario else 'n_0086'
    print(f"실행 {len(rows)}번, 비용 합계 ${sum(r['cost'] for r in rows):.2f}")
    print('칸 | 모델 | 실행 | 작업 방식 노트를 엶 | 연 노트 수(평균) | brain find(평균) | brain toc(평균) | 스킬 읽음 | 설계 문서를 바로 씀 | 웹 검색(평균) | 입력 토큰(평균) | 비용(평균) | 상한에 끊김')
    keys = sorted({(r['variant'], r['arm'], r['model']) for r in rows})
    for variant, arm, model in keys:
        sel = [r for r in rows if (r['variant'], r['arm'], r['model']) == (variant, arm, model)]
        fs = [facts(r, target) for r in sel]
        n = len(sel)
        avg = lambda k: sum((len(f[k]) if isinstance(f[k], list) else f[k]) for f in fs) / n
        print(f"{VARIANTS.get(variant, variant)}·{ARMS.get(arm, arm)} | {model} | {n} | {sum(f['opened'] for f in fs)}/{n} | {avg('shows'):.1f} | {avg('finds'):.1f} | {avg('tocs'):.1f} | "
              f"{sum(f['skill'] for f in fs)}/{n} | {sum(bool(f['wrote']) for f in fs)}/{n} | {avg('web'):.1f} | {avg('input_total'):,.0f} | ${sum(r['cost'] for r in sel) / n:.2f} | {sum(f['cut'] for f in fs)}/{n}")
    print('\n실행별 (답 원문은 answers/ 폴더에서 읽고 판정한다):')
    for r in rows:
        f = facts(r, target)
        print(f"{r['name']}: 엶 {'O' if f['opened'] else 'X'} · 연 노트 {','.join(f['shows']) or '-'} · find {f['finds']} · toc {f['tocs']} · 목차 붙음 {'O' if r.get('toc_marked') else '-'} · 쓴 문서 {len(f['wrote'])} · ${r['cost']:.2f} · {r['seconds']}초{' · 끊김' if f['cut'] else ''}")


def live(a):
    scenario = json.load(open(a.scenario))
    # 판을 번갈아 돌린다 (기존 1, 새 판 1, 기존 2 …): 시간대에 따른 차이가 한 판에 몰리지 않게.
    runs = [(cell, model, rep) for model in a.models.split(',') for rep in range(1, a.reps + 1) for cell in a.cells.split(',')]
    worst = sum(CAPS.get(m, 1.0) for _, m, _ in runs)
    if not a.run:
        for cell, model, rep in runs:
            print(cell, model, rep, f'상한 ${CAPS.get(model, 1.0):.2f}')
        print(f'모두 {len(runs)}번, 실행마다 턴 {len(scenario["turns"])}개, 최악 ${worst:.2f} (합계 상한 --budget {a.budget})')
        return
    os.makedirs(a.out, exist_ok=True)
    path = os.path.join(a.out, 'results.jsonl')
    done = {json.loads(l)['name'] for l in open(path)} if os.path.exists(path) else set()
    spent = sum(json.loads(l)['cost'] for l in open(path)) if os.path.exists(path) else 0.0
    for cell, model, rep in runs:
        name = f"{cell.replace(':', '-')}-{model}-{rep}"
        if name in done:
            continue
        cap = CAPS.get(model, 1.0)
        if spent + cap > a.budget:
            print(f'비용 한도 ${a.budget}에 닿을 수 있어 멈춤 (쓴 것 ${spent:.2f})')
            break
        row = run_live(a, cell, model, rep, cap, scenario)
        spent += row['cost']
        f = facts(row, scenario['target'])
        print(f"{row['name']}: 작업 방식 노트 {'엶' if f['opened'] else '안 엶'} · 연 노트 {len(f['shows'])} · find {f['finds']} · toc {f['tocs']} · ${row['cost']:.2f} (합계 ${spent:.2f}) · {row['seconds']}초", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=['replay', 'recall', 'live', 'report'])
    ap.add_argument('--base'); ap.add_argument('--new'); ap.add_argument('--vault')
    ap.add_argument('--work', default=os.environ.get('TMPDIR', '/tmp'), help='사본을 둘 임시 폴더 (저장소 밖)')
    ap.add_argument('--plugins'); ap.add_argument('--scenario'); ap.add_argument('--out')
    ap.add_argument('--cells', default='then:base,then:new,now:base,now:new'); ap.add_argument('--models', default='claude-sonnet-5-5')
    ap.add_argument('--reps', type=int, default=3); ap.add_argument('--budget', type=float, default=3.0)
    ap.add_argument('--run', action='store_true'); ap.add_argument('--plan', action='store_true')
    a = ap.parse_args()
    for path in (a.work, a.out):
        if path and os.path.realpath(path).startswith(REPO + os.sep):
            sys.exit('결과·사본 폴더는 저장소 밖에 둡니다 (사용자 문장과 노트 내용이 들어갑니다).')
    {'replay': replay, 'recall': recall, 'live': live, 'report': report}[a.mode](a)


if __name__ == '__main__':
    main()
