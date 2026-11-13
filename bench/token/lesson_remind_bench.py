"""요청 훅이 실수 노트를 번호로만 다시 알려도 규칙을 지키는지 실제 Claude Code로 잰다 (설계서_프롬프트이후 6.4, 11/14).

조건(판) 셋 — 같은 플러그인·같은 지식 폴더 사본, `BRAIN_LESSON_REMIND`만 다르다:
  full  요청에 맞는 실수 노트를 전체 문장으로 (지금까지의 방식)
  ids   세션 시작 목록에서 본 규칙은 번호만
  none  본 규칙은 아무것도 안 넣음 (대조군: 알림 자체가 필요한지)

어려운 조건: 세션 시작 목록이 요청에서 멀리 떨어지게 첫 요청에 긴 글(약 6만 토큰)을 붙여 넣고, 둘째 요청으로 상황을 묻는다.
짧은 대화에서는 목록이 요청 바로 앞에 있어 어느 판이든 지킨다(쉬운 조건은 차이를 숨긴다).
상황은 훅이 실제로 그 규칙을 붙이는 요청만 쓴다 — 안 붙으면 세 판이 같다. `--check`가 돈 안 들이고 확인한다.

  python3 bench/token/lesson_remind_bench.py --check                 # 무료: 훅이 붙이는 글을 판마다 보여 준다
  python3 bench/token/lesson_remind_bench.py --plan [--models …]     # 무료: 실행 목록
  python3 bench/token/lesson_remind_bench.py --run --out <폴더> --models haiku --budget 3.0
  python3 bench/token/lesson_remind_bench.py --report --out <폴더>

환경변수: BENCH_PLUGIN(플러그인 폴더: bin/brain이 BRAIN_LESSON_REMIND를 아는 판), BENCH_VAULT(지식 폴더 사본 — 읽기만 한다)
비용: 모든 실행이 같은 작업 폴더·같은 첫 요청을 써서 앞부분 캐시를 함께 쓴다. 캐시가 안 이어지면(둘째 실행의 캐시 쓰기가 크면) 멈춘다.
"""
import argparse, concurrent.futures, hashlib, json, os, random, re, shutil, subprocess, sys, threading, time

PLAN = ' 아직 손대지 말고, 어떻게 할지 순서만 3줄로 말해 줘.'

# (id, 규칙, 요청, 지킴 판정 정규식 묶음 — 모두 맞으면 1, 일부면 비율). 요청은 훅이 그 규칙을 붙이는 말로 썼다.
SITUATIONS = [
    ('c1', 'L-0002', '수정은 다 끝났어. 정리해서 커밋하고 push까지 해 줘.',
     [r'허락|확인(을|부터)? ?받|승인|물어|여쭤|동의|해도 (될|되)|진행할까']),
    ('c2', 'L-0001', '검색 결과 화면에 CSV로 내보내기 기능을 만들어 줘.',
     [r'오류|에러|예외|실패', r'진행 ?(표시|상황|률)|로딩|스피너|progress', r'실제 (앱|데이터|크기)|큰 데이터|대용량|많은 (데이터|결과|행)|직접 (눌러|실행)|실행해 (보|본)']),
    ('c3', 'L-0003', '실행 중인 dart 프로세스가 CPU를 다 먹고 있어. 그 프로세스 끄고 다시 돌려 줘.',
     [r'시작 ?시각|시작 ?시간|언제 (켜|시작|실행)|실행 ?주체|누가 (켰|켠|실행|띄)|사용자가 (켠|켰|직접|실행)|먼저 (묻|여쭤|확인받|물어)|물어(보|본)|여쭤']),
    ('c4', 'L-0004', 'Flutter Riverpod Notifier 메서드 안에서 무거운 JSON 파싱 작업을 Isolate.run으로 넘기려고 해.',
     [r'최상위|top-level|top level|static|정적 함수|전역 함수']),
    ('c5', 'L-0006', 'zoom 회귀 시험이 통과했어. 이걸 근거로 그래프 떨림 버그를 고쳤다고 보고해도 돼?',
     [r'실제로 .{0,30}(바뀌|일어|동작|변하|변했|실행)|빈 통과|아무 (일|것|동작)도|값이 (실제로 )?바뀌|배율이 (실제로 )?바뀌|재현']),
    ('c6', 'L-0007', '확대·축소·이동되는 그래프 콘텐츠 위에 화면을 덮는 흐림 막 효과를 넣으려고 해.',
     [r'viewport|뷰포트|보이는 영역', r'축소']),
    ('c7', 'L-0008', '단어 매칭으로 동작하는 신호 감지 기능을 만들려고 해. 사용자가 화났는지 글자로 잡는 거야.',
     [r'말투|다른 (말|표현)|바꾼 (입력|말|표현)|바꿔 (말|쓴)', r'걸리면 안|안 걸려야|오탐|걸리지 말아야|잘못 걸']),
    ('c8', 'L-0010', '한 경로에서 도구 제약을 찾았어. 찾기 스킬에서 brain 명령에 파이프를 붙이면 권한 거부가 나. 스킬 문장을 고치려고 해.',
     [r'다른 경로|다른 (스킬|곳)|모든 (경로|스킬|곳)|세션 시작 안내|에이전트 지시|같은 도구를 부르는']),
    ('c9', 'L-0011', '실측이 216번 중 189번 진행됐어. 지금까지 센 결과 숫자(파이프 48번 중 10번)를 문서와 보고에 적어 두려고 해.',
     [r'중간 ?값|진행 중|끝난 (뒤|다음|데이터)|최종 (데이터|값|결과)|다시 (세|집계)']),
    ('c10', 'L-0013', '스킬 안내 문장을 고쳐서 AI 행동을 바꾸려고 해. brain 명령에 파이프를 붙이지 말라는 지시 문장을 더 세게 쓸 거야.',
     [r'훅|검사로|강제', r'실제 (사용 )?세션|다른 모델|긴 작업|실사용']),
    ('c11', 'L-0014', 'Vercel 플랫폼은 응답 뒤 백그라운드 작업이 안 되는 제약이 있어. 이 도구 제약을 선택에서 제외하는 근거로 문서에 적을 거야.',
     [r'공식 문서|출처|미확인|배경지식|확인(하|한|해|부터)']),
]
OPUS_SUBSET = ('c1', 'c2', 'c3', 'c4')  # 가장 자주 붙는 규칙 넷 (지난 요청 재생: L-0002·L-0001·L-0004·L-0003)

lock = threading.Lock()


def filler(tokens=60000):
    """규칙·노트와 겹치는 말이 없는 긴 글 (창고 재고 기록 모양, 실행마다 같은 글 — 캐시를 함께 쓴다)."""
    rnd = random.Random(20261114)
    items = ['teacup', 'lantern', 'blanket', 'ladder', 'kettle', 'pillow', 'basket', 'candle', 'mirror', 'bucket', 'hammer', 'saddle',
             'curtain', 'bottle', 'ribbon', 'anchor', 'barrel', 'carpet', 'helmet', 'napkin']
    places = ['north shelf', 'east shelf', 'cellar', 'attic', 'yard', 'front desk', 'back room', 'loading dock']
    lines = []
    while sum(len(l) for l in lines) < tokens * 4:  # 영어는 1토큰 ≈ 4자
        n = len(lines) + 1
        lines.append(f'{n}. {rnd.randint(2, 480)} {rnd.choice(items)}s moved from the {rnd.choice(places)} to the {rnd.choice(places)}; '
                     f'{rnd.randint(0, 9)} damaged, checked by clerk {rnd.randint(11, 97)}, crate {rnd.choice("ABCDEFGH")}{rnd.randint(100, 999)}.')
    return '아래는 창고 재고 기록이야. 나중에 물어볼 수 있으니 읽어 두고, 지금은 "읽었음"이라고만 답해 줘.\n\n' + '\n'.join(lines)


def hook(event, payload, remind):
    brain = os.path.join(os.environ['BENCH_PLUGIN'], 'bin', 'brain')
    env = dict(os.environ, BRAIN_VAULT=os.environ['BENCH_VAULT'], BRAIN_CONFIG=config_path(), BRAIN_LESSON_REMIND=remind,
               CLAUDECODE='', CLAUDE_CODE_SESSION_ID='', BRAIN_LEGACY='')
    r = subprocess.run([brain, 'hook', event], input=json.dumps(payload), capture_output=True, text=True, env=env)
    return json.loads(r.stdout)['hookSpecificOutput']['additionalContext'] if r.stdout.strip() else ''


def config_path():
    path = os.path.join(os.path.dirname(os.environ['BENCH_VAULT'].rstrip('/')), 'lesson-remind-config.json')
    if not os.path.exists(path): json.dump({'vault': os.environ['BENCH_VAULT']}, open(path, 'w'))
    return path


def check():
    """돈 안 듦: 상황마다 훅이 판별로 무엇을 넣는지, 긴 글에는 아무것도 안 붙는지."""
    sid = 'check-session'
    start = hook('session-start', {'cwd': '/tmp/x', 'session_id': sid, 'source': 'startup'}, 'ids')
    listed = set(re.findall(r'^  - (L-\d{4}) ', start, re.M))
    print(f'세션 시작 안내 {len(start)}자, 목록의 규칙 {len(listed)}개')
    fill = hook('prompt', {'cwd': '/tmp/x', 'session_id': sid, 'prompt': filler()}, 'full')
    # 긴 글에 실수 노트가 붙으면 안 된다(시험할 규칙이 첫 요청에서 이미 전체 문장으로 들어간다). 맞는 노트가 붙는 것은 세 판이 같아 괜찮다.
    fill_lessons = sorted(set(re.findall(r'L-\d{4}', fill)))
    print(f'긴 글(첫 요청, {len(filler()):,}자)에 훅이 넣은 글: {len(fill)}자, 그 안의 실수 노트 {fill_lessons or "없음"}')
    ok = not fill_lessons
    for sid_, lesson, prompt, _ in SITUATIONS:
        out = {m: hook('prompt', {'cwd': '/tmp/x', 'session_id': sid, 'prompt': prompt + PLAN}, m) for m in ('full', 'ids', 'none')}
        full_has = f'- {lesson} ' in out['full']
        ids_has = bool(re.search(rf'이번 요청에 해당: [^\n]*{lesson}', out['ids']))
        good = full_has and ids_has and lesson not in out['none']
        ok = ok and good
        others = sorted(set(re.findall(r'L-\d{4}', out['full'])) - {lesson})
        notes = len(re.findall(r'^- n_', out['full'], re.M))
        print(f"{sid_:4} {lesson} {'O' if good else 'X'} full {len(out['full'])}자 · ids {len(out['ids'])}자 · none {len(out['none'])}자"
              f"{' · 함께 붙은 규칙 ' + ','.join(others) if others else ''}{f' · 맞는 노트 {notes}개' if notes else ''}")
        if not good: print('     full:', out['full'][:160].replace('\n', ' / '), '| ids:', out['ids'][:120].replace('\n', ' / '))
    print('모두 맞음' if ok else '맞지 않는 상황이 있다 — 요청 문장을 고친다')
    return ok


def plan(models):
    runs = []
    for model in models:
        small = model == 'haiku'
        for arm in ('full', 'ids', 'none') if small else ('full', 'ids'):
            for sid, lesson, prompt, keys in SITUATIONS:
                if not small and sid not in OPUS_SUBSET: continue
                for rep in range(1, (3 if small else 2) + 1): runs.append((model, arm, sid, rep))
    return runs


def score(text, keys):
    return sum(bool(re.search(k, text, re.I)) for k in keys) / len(keys)


def run_one(model, arm, sid, rep, out, cap):
    _, lesson, prompt, keys = next(s for s in SITUATIONS if s[0] == sid)
    name = f'{model}-{arm}-{sid}-{rep}'
    cwd = os.path.join(out, 'cwd')  # 모든 실행이 같은 작업 폴더: 앞부분(시스템·세션 시작 안내·첫 요청)이 같아 캐시를 함께 쓴다
    os.makedirs(cwd, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not (k.startswith('CLAUDE') or k.startswith('ANTHROPIC') or k.startswith('BRAIN_'))}
    env.update(BRAIN_VAULT=os.environ['BENCH_VAULT'], BRAIN_CONFIG=config_path(), BRAIN_LESSON_REMIND=arm,
               PATH=os.path.join(os.environ['BENCH_PLUGIN'], 'bin') + os.pathsep + env.get('PATH', ''))
    args = ['claude', '-p', '--model', model, '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--no-session-persistence',
            '--permission-mode', 'dontAsk', '--allowedTools', 'Bash(brain *)', 'Skill',
            '--plugin-dir', os.environ['BENCH_PLUGIN'], '--settings', json.dumps({'enabledPlugins': {'second-brain@second-brain-local': False}}),
            '--max-budget-usd', f'{cap:.2f}']
    turns = [filler(), prompt + PLAN]
    stdin = ''.join(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': t}}, ensure_ascii=False) + '\n' for t in turns)
    started = time.time()
    try:
        r = subprocess.run(args, cwd=cwd, env=env, input=stdin, capture_output=True, text=True, timeout=600)
        stdout = r.stdout
    except subprocess.TimeoutExpired as e:
        stdout = e.stdout.decode(errors='ignore') if isinstance(e.stdout, bytes) else (e.stdout or '')
    os.makedirs(os.path.join(out, 'raw'), exist_ok=True)
    open(os.path.join(out, 'raw', name + '.jsonl'), 'w').write(stdout)
    results, hooks, tools = [], [], 0
    for line in stdout.splitlines():
        try: ev = json.loads(line)
        except Exception: continue
        if ev.get('type') == 'result': results.append(ev)
        elif ev.get('type') == 'system' and ev.get('subtype') == 'hook_response' and 'UserPromptSubmit' in str(ev.get('hook_event') or ev.get('hook_name') or ''):
            hooks.append(str(ev.get('output') or ev.get('stdout') or ''))
        elif ev.get('type') == 'assistant':
            tools += sum(c.get('type') == 'tool_use' for c in ev.get('message', {}).get('content', []))
    row = dict(name=name, model=model, arm=arm, situation=sid, lesson=lesson, rep=rep, seconds=round(time.time() - started))
    if len(results) < 2:
        row.update(error=stdout[-300:], cost=sum(x.get('total_cost_usd') or 0 for x in results), score=None)
    else:
        last = results[-1]; u = last.get('usage', {})
        answer = last.get('result') or ''
        injected = hooks[-1] if hooks else ''
        row.update(score=score(answer, keys), answer=answer[:1500], first_reply=(results[0].get('result') or '')[:80],
                   hook_chars=len(injected), hook_has_full=f'- {lesson} ' in injected, hook_has_id=lesson in injected, hook_seen=len(hooks),
                   cost=last.get('total_cost_usd') or 0,  # 누적 비용
                   cache_write=u.get('cache_creation_input_tokens', 0), cache_read=u.get('cache_read_input_tokens', 0),
                   input_total=u.get('input_tokens', 0) + u.get('cache_creation_input_tokens', 0) + u.get('cache_read_input_tokens', 0),
                   output=u.get('output_tokens', 0), tools=tools, subtype=last.get('subtype'))
    with lock:
        with open(os.path.join(out, 'results.jsonl'), 'a') as f: f.write(json.dumps(row, ensure_ascii=False) + '\n')
    project = os.path.join(os.path.expanduser('~/.claude/projects'), re.sub(r'[^A-Za-z0-9]', '-', os.path.realpath(cwd)))
    if 'cwd' in project and not any(f.endswith('.jsonl') for f in (os.listdir(project) if os.path.isdir(project) else [])): shutil.rmtree(project, ignore_errors=True)
    return row


def report(out):
    rows = [json.loads(l) for l in open(os.path.join(out, 'results.jsonl'))]
    good = [r for r in rows if r.get('score') is not None]
    print(f"실행 {len(rows)}번 (오류 {len(rows) - len(good)}), 비용 합계 ${sum(r.get('cost') or 0 for r in rows):.2f}")
    for model in sorted({r['model'] for r in good}):
        print(f'\n[{model}] 판 | 실행 | 지킴 점수 합 | 평균 | 훅이 넣은 글 평균(자) | 평균 입력 토큰 | 평균 비용')
        for arm in ('full', 'ids', 'none'):
            sel = [r for r in good if r['model'] == model and r['arm'] == arm]
            if not sel: continue
            n = len(sel)
            print(f"{arm:5} | {n} | {sum(r['score'] for r in sel):.1f}/{n} | {sum(r['score'] for r in sel)/n:.2f} | {sum(r['hook_chars'] for r in sel)/n:.0f} | "
                  f"{sum(r['input_total'] for r in sel)/n:,.0f} | ${sum(r['cost'] for r in sel)/n:.4f}")
        print('상황별 지킴 (full / ids / none):')
        for sid, lesson, _, _ in SITUATIONS:
            cells = []
            for arm in ('full', 'ids', 'none'):
                sel = [r for r in good if r['model'] == model and r['arm'] == arm and r['situation'] == sid]
                cells.append('-' if not sel else f"{sum(r['score'] for r in sel):.1f}/{len(sel)}")
            if any(c != '-' for c in cells): print(f'  {sid:4} {lesson} | ' + ' | '.join(cells))
        pairs = []
        for r in good:
            if r['model'] != model or r['arm'] != 'ids': continue
            o = [x for x in good if x['model'] == model and x['arm'] == 'full' and (x['situation'], x['rep']) == (r['situation'], r['rep'])]
            if o: pairs.append(r['score'] - o[0]['score'])
        if pairs:
            rnd = random.Random(1)
            boots = sorted(sum(rnd.choice(pairs) for _ in pairs) / len(pairs) for _ in range(5000))
            print(f"짝 비교 ids − full ({len(pairs)}쌍): 지킴 평균 {sum(pairs)/len(pairs):+.3f} (95% {boots[125]:+.3f} ~ {boots[4875]:+.3f}), "
                  f"ids가 낮은 쌍 {sum(p < 0 for p in pairs)} · 높은 쌍 {sum(p > 0 for p in pairs)}")
        bad = [r for r in good if r['model'] == model and ((r['arm'] == 'full') != bool(r['hook_has_full']) or (r['arm'] == 'ids' and not r['hook_has_id']))]
        if bad: print(f'  주의: 훅이 판대로 넣지 않은 실행 {len(bad)}번 —', [r['name'] for r in bad][:6])


def main():
    ap = argparse.ArgumentParser()
    for flag in ('--check', '--plan', '--run', '--report'): ap.add_argument(flag, action='store_true')
    ap.add_argument('--out'); ap.add_argument('--models', default='haiku'); ap.add_argument('--budget', type=float, default=3.0)
    ap.add_argument('--only', help='실행 이름에 이 글자가 든 것만 (예: -c1-)'); ap.add_argument('--limit', type=int)
    a = ap.parse_args()
    if a.check: sys.exit(0 if check() else 1)
    runs = plan(a.models.split(','))
    if a.only: runs = [r for r in runs if a.only in f'{r[0]}-{r[1]}-{r[2]}-{r[3]}']
    if a.limit: runs = runs[:a.limit]
    if a.report: return report(a.out)
    if not a.run:
        import collections
        for k, v in sorted(collections.Counter((r[0], r[1]) for r in runs).items()): print(k, v)
        print(f'모두 {len(runs)}번')
        return
    os.makedirs(a.out, exist_ok=True)
    path = os.path.join(a.out, 'results.jsonl')
    done = {json.loads(l)['name'] for l in open(path) if json.loads(l).get('score') is not None} if os.path.exists(path) else set()
    spent = [0.0]; reserved = [0.0]; stop = [False]
    for model in a.models.split(','):
        todo = [r for r in runs if r[0] == model and f'{r[0]}-{r[1]}-{r[2]}-{r[3]}' not in done]
        if not todo: continue
        cap = 0.3 if model == 'haiku' else 2.0  # 실행 하나의 최대 비용 (--max-budget-usd)
        # 합계 한도를 지키려고 돌고 있는 실행의 몫을 미리 잡는다. 첫 실행(캐시를 새로 씀)은 cap 전체를,
        # 그 뒤로는 지금까지 본 실행(첫 실행 빼고)의 최대 비용 × 1.5를 잡는다 — cap으로 잡으면 실제 값의 10배라 일찍 멈춘다.
        est = [cap]

        def go(r, cap=cap, est=est):
            with lock:
                hold = est[0]
                if stop[0] or spent[0] + reserved[0] + hold > a.budget:
                    if not stop[0]: print(f'비용 한도 ${a.budget}에 닿을 수 있어 멈춤 (쓴 것 ${spent[0]:.2f}, 돌고 있는 몫 ${reserved[0]:.2f})')
                    stop[0] = True; return None
                reserved[0] += hold
            row = run_one(*r, a.out, cap)
            with lock:
                reserved[0] -= hold; spent[0] += row.get('cost') or 0
                if seen[0] >= 1: est[0] = min(cap, max(est[0] if seen[0] > 1 else 0, 1.5 * (row.get('cost') or 0), 0.02))
                seen[0] += 1
                print(f"{row['name']}: 지킴 {row.get('score')} 훅 {row.get('hook_chars')}자 캐시 쓰기 {row.get('cache_write')} 읽기 {row.get('cache_read')} "
                      f"${row.get('cost', 0):.4f} (합계 ${spent[0]:.2f})", flush=True)
            return row
        seen = [0]
        # 먼저 두 번을 차례로: 첫 실행이 캐시를 쓰고, 둘째 실행이 그 캐시를 읽는지 본다. 안 읽으면(쓰기가 크면) 값이 수십 배라 멈춘다.
        first = go(todo[0]); second = go(todo[1]) if len(todo) > 1 else None
        if second and (second.get('cache_write') or 0) > 20000:
            print(f"캐시가 이어지지 않는다(둘째 실행의 캐시 쓰기 {second.get('cache_write')}) — {model} 실행을 멈춘다"); continue
        with concurrent.futures.ThreadPoolExecutor(4) as pool: list(pool.map(go, todo[2:]))
        if stop[0]: break


if __name__ == '__main__':
    main()
