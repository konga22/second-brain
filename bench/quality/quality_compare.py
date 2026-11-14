"""지식 품질 기준 적용 전·후 비교 (작업 지시서 7번, 설계서_프롬프트이후 5.9). 돈 안 듦. 실제 지식 폴더는 건드리지 않는다.

  python3 bench/quality/quality_compare.py <전: 지식 폴더 사본> <후: 만들 폴더> [--replay]

1. 전 사본을 복사해 judgments_20261114.py의 고침(EDITS)·보관(ARCHIVE)·합침(MERGE)을 적용한 "후" 판을 만든다.
2. 두 판에서 같은 것을 잰다: 노트 수, 점검(brain lint), 찾기 정확도(bench/questions.yaml 30개 + questions_casual.yaml),
   바뀐 지식 질문(_meta/quality/questions_changed.yaml)에서 찾기 상위에 지금 답이 있는지·옛 주장이 요약에 그대로 있는지.
3. --replay: 이 맥의 지난 사용자 요청을 요청 훅에 다시 넣어, 낡은 요약이 AI에게 간 횟수를 센다(요청 내용은 출력하지 않는다).
환경변수 BRAIN: brain 실행 파일 (기본 assets/brain/bin/brain)
"""
import glob, hashlib, json, os, re, shutil, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__)); repo = os.path.dirname(os.path.dirname(here))
# 노트별 판정·고침 문장·바뀐 지식 질문은 노트 내용을 담고 있어 저장소에 두지 않는다(지식은 기기에만).
# 지식 폴더 _meta/quality/에 두고, 다른 자리면 BRAIN_QUALITY_DATA로 알려 준다.
data = os.environ.get('BRAIN_QUALITY_DATA', os.path.expanduser('~/SecondBrain/_meta/quality'))
if not os.path.exists(os.path.join(data, 'judgments_20261114.py')):
    sys.exit(f'판정 자료가 없습니다: {data}/judgments_20261114.py (BRAIN_QUALITY_DATA로 자리를 알려 주세요)')
sys.path.insert(0, data)
import judgments_20261114 as J
BRAIN = os.environ.get('BRAIN', os.path.join(repo, 'assets', 'brain', 'bin', 'brain'))


def env(vault):
    cfg = vault.rstrip('/') + '-config.json'
    if not os.path.exists(cfg): json.dump({'vault': vault}, open(cfg, 'w'))
    return dict(os.environ, BRAIN_VAULT=vault, BRAIN_CONFIG=cfg, CLAUDECODE='', CLAUDE_CODE_SESSION_ID='', BRAIN_LEGACY='')


def brain(vault, *args, stdin=None):
    r = subprocess.run([BRAIN, *args], input=stdin, capture_output=True, text=True, env=env(vault))
    return r.stdout + r.stderr


def notes(vault):
    out = {}
    for d, _, fs in os.walk(os.path.join(vault, 'wiki')):
        for f in fs:
            if not f.endswith('.md'): continue
            p = os.path.join(d, f); t = open(p, errors='ignore').read()
            m = re.search(r'^id: (n_\d+)', t, re.M)
            if m: out[m.group(1)] = (p, t)
    return out


def build_after(before, after):
    if os.path.exists(after): shutil.rmtree(after)
    shutil.copytree(before, after, symlinks=True)
    ns = notes(after)
    for nid, edits in J.EDITS.items():
        p, t = ns[nid]
        for old, new in edits:
            assert t.count(old) == 1, f'{nid}: 옛 글이 {t.count(old)}번 있다 — {old[:40]}'
            t = t.replace(old, new)
        open(p, 'w').write(t)
    held = os.path.join(after, '보관(후 판)')
    os.makedirs(held)
    for nid in J.ARCHIVE + list(J.MERGE):
        shutil.move(ns[nid][0], os.path.join(held, os.path.basename(ns[nid][0])))
    brain(after, 'index')


def yaml_questions(path):
    qs = []; cur = None
    for line in open(path):
        if line.startswith('- q:'): cur = {'q': line[4:].strip().strip('"')}; qs.append(cur)
        elif cur is not None and ':' in line and not line.lstrip().startswith('#'):
            k, v = line.strip().split(':', 1); v = v.strip()
            cur[k] = re.findall(r'n_\d+', v) if k == 'expect' else v.strip("'")
    return qs


def find_ids(vault, q):
    return re.findall(r'^(n_\d{4})  ', brain(vault, 'find', q), re.M)


def recall(vault, qs, redirect):
    hit = top1 = n = 0; none_ok = none_n = 0
    for q in qs:
        ids = find_ids(vault, q['q'])
        expect = [redirect.get(e, e) for e in q.get('expect', [])]
        if not expect:
            none_n += 1; none_ok += not ids; continue
        n += 1; hit += any(e in ids for e in expect); top1 += bool(ids) and ids[0] in expect
    return hit, top1, n, none_ok, none_n


def changed(vault, qs):
    ns = notes(vault); now_top3 = old_shown = old_only = 0; rows = []
    for q in qs:
        out = brain(vault, 'find', q['q']); ids = re.findall(r'^(n_\d{4})  ', out, re.M)
        shown_old = bool(re.search(q['old'], out, re.M))                     # AI가 처음 보는 글(제목·요약)에 옛 주장
        texts = [ns[i][1] for i in ids[:3] if i in ns]
        has_now = any(re.search(q['now'], t, re.M) for t in texts)          # 상위 3개 노트 본문에 지금 답
        has_old = any(re.search(q['old'], t, re.M) for t in texts)          # 상위 3개 노트 본문에 고쳐지지 않은 옛 주장
        now_top3 += has_now; old_shown += shown_old; old_only += has_old
        rows.append((q['q'][:28], ids[:3], '지금 답 있음' if has_now else '지금 답 없음', '옛 주장 남음' if has_old else '-'))
    return now_top3, old_only, old_shown, rows


def replay(vault):
    """지난 사용자 요청을 요청 훅에 다시 넣어, 낡은 요약(STALE_SUMMARY)이 그대로 AI에게 간 횟수."""
    ns = notes(vault); stale_now = set()
    for nid in J.STALE_SUMMARY:  # 이 판에서 그 노트의 요약이 아직 옛 글인가
        if nid in ns and not any(new.startswith('summary:') and new in ns[nid][1] for old, new in J.EDITS.get(nid, [])): stale_now.add(nid)
    prompts = 0; injected = 0; stale = 0
    for f in glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl')):
        for line in open(f, errors='ignore'):
            if '"type":"user"' not in line: continue
            try: ev = json.loads(line)
            except Exception: continue
            if ev.get('type') != 'user' or ev.get('isMeta') or ev.get('isSidechain'): continue
            c = (ev.get('message') or {}).get('content')
            if not isinstance(c, str) or not c.strip() or c.startswith('<command-') or c.startswith('<local-command'): continue
            prompts += 1
            out = brain(vault, 'hook', 'prompt', stdin=json.dumps({'prompt': c, 'cwd': '/tmp'}))
            ids = set(re.findall(r'- (n_\d{4}) ', out))
            injected += bool(ids); stale += bool(ids & stale_now)
    return prompts, injected, stale


def main():
    before, after = sys.argv[1], sys.argv[2]
    build_after(before, after)
    brain(before, 'index')
    redirect = dict(J.MERGE)
    q30 = yaml_questions(os.path.join(repo, 'bench', 'questions.yaml'))
    qc = yaml_questions(os.path.join(repo, 'bench', 'questions_casual.yaml'))
    qx = yaml_questions(os.path.join(data, 'questions_changed.yaml'))
    for label, vault in (('전', before), ('후', after)):
        ns = notes(vault)
        chars = sum(len(t.split('---', 2)[2]) for _, t in ns.values())
        lint = brain(vault, 'lint')
        lint_counts = dict(re.findall(r'^(\S[^\n]*?) (\d+)개$', lint, re.M))
        h, t1, n, _, _ = recall(vault, q30, redirect)
        hc, t1c, nc, ok0, n0 = recall(vault, qc, redirect)
        now3, old3, shown, rows = changed(vault, qx)
        print(f'\n== {label} ({vault})')
        print(f'노트 {len(ns)}개, 본문 {chars:,}자')
        print(f'점검(brain lint): {lint_counts or "문제 없음"}')
        print(f'찾기 30문: 5위 안 {h}/{n}, 1위 {t1}/{n} · 평소 말투 {nc}문: 5위 안 {hc}/{nc}, 1위 {t1c}/{nc}, 답 없는 {n0}문에 아무것도 안 냄 {ok0}/{n0}')
        print(f'바뀐 지식 {len(qx)}문: 상위 3개 노트에 지금 답 {now3}/{len(qx)} · 상위 3개에 고쳐지지 않은 옛 주장 {old3}/{len(qx)} · 찾기 결과 글(제목·요약)에 옛 주장 {shown}/{len(qx)}')
        for r in rows: print('   ', r[0], r[1], r[2], r[3])
        if '--replay' in sys.argv:
            p, inj, st = replay(vault)
            print(f'지난 요청 {p}개를 훅에 다시 넣음: 노트를 미리 넣은 요청 {inj}번, 그 가운데 낡은 요약이 그대로 간 요청 {st}번')
    for v in (before, after):  # 색인 캐시 정리 (이 스크립트가 만든 것)
        cache = os.path.join(os.path.expanduser('~/Library/Caches/com.konga22.secondbrain'), hashlib.sha1(v.encode()).hexdigest()[:12])
        shutil.rmtree(cache, ignore_errors=True)


if __name__ == '__main__':
    main()
