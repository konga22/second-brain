"""세컨드 브레인 있음/없음 비교 실측 (docs/사용가치분석.md).

조건 4개 (모두 같은 질문, 같은 모델, 지식 폴더 사본):
  A 없음      : 기억 없음. 빈 작업 폴더, 플러그인 끔. 디스크의 프로젝트 파일은 뒤질 수 있음(실제 사용 그대로)
  B 메모폴더  : 같은 노트를 md 폴더로 두고 CLAUDE.md에 "거기서 찾아라" 한 줄. AI가 Grep/Read로 직접 찾음
  C 통째로    : 같은 노트 전부를 작업 폴더 CLAUDE.md에 넣음 (늘 문맥에)
  D 세컨드브레인: 플러그인 켬 (찾기 방식 R 기본)

VALUE_DIR=<작업 폴더> [CMP_WORKERS=8] python3 bench/value/run.py <세트 k,m,u> <반복> <출력 jsonl> [모델] [조건 A,B,C,D] [질문 id만]
돈이 든다: Haiku 216번(질문 18·실수 6·무관 3 × 조건 4 × 2번) 약 $2
"""
import json, os, os, re, subprocess, sys, random, time
from concurrent.futures import ThreadPoolExecutor

CMP = os.environ['VALUE_DIR']  # bench/value/setup.sh로 만든 작업 폴더
PLUGIN_BIN = os.path.expanduser('~/Library/Application Support/com.konga22.secondbrain/claude-code/second-brain/bin')

K = ' 짧게 답해 줘.'
M = ' 아직 손대지 말고, 어떻게 할지 순서만 3줄로 말해 줘.'

# 지식 질문: keys = 모두 맞아야 정답인 정규식 묶음. kind P=개인 결정(일반 지식으로 못 맞힘) G=일반 지식으로도 근접 가능
KNOW = [
    ('k01', 'P', 'n_0046', '카카오톡 봇 이벤트 받는 방식 뭘로 하기로 했었지?', [r'게이트웨이|웹소켓|websocket']),
    ('k02', 'P', 'n_0042', '한반도감 서버 다시 올리려면 뭐부터 해야 한다고 정리했었지?', [r'fork|포크', r'terraform|테라폼']),
    ('k03', 'P', 'n_0045', '한반도감 작품 제작 리포트에 적은 팀명이 뭐였지?', [r'담비']),
    ('k04', 'P', 'n_0026', 'FAT32 USB에서 Flutter 개발할 때 어떻게 하기로 했었지?', [r'sparsebundle|스파스번들|디스크 이미지']),
    ('k05', 'P', 'n_0008', 'game-ai-research-kit에서 디스코드 웹훅 주소는 어디서 읽게 했지?', [r'DISCORD_WEBHOOK_URL']),
    ('k06', 'P', 'n_0002', '회의록 앱 용량 줄일 때 받아쓰기를 뭘로 바꾸기로 했지?', [r'SpeechAnalyzer|SpeechTranscriber|Apple 내장|애플 내장']),
    ('k07', 'P', 'n_0050', '대회 교차 검증용으로 Kiro 구독하기로 했었나?', [r'안 하기로|쓰지 않기로|안 쓰기로|하지 않기로|구독하지 않|버리|안 했|Claude만|Claude 단독|아니']),
    ('k08', 'P', 'n_0049', 'AI_TOP_100 예선에서 제출은 몇 번 할 수 있었지?', [r'1회|한 번|1번|단 한']),
    ('k09', 'P', 'n_0038', 'Isolate.run에 클로저 넘겼다가 났던 오류 뭐였지? 어떻게 고쳤더라', [r'unsendable', r'최상위|top-level|top level']),
    ('k10', 'P', 'n_0014', '앱에서 claude -p 돌릴 때 --bare 옵션 써도 됐었나?', [r'OAuth|구독 로그인|로그인', r'못|안 ?돼|안 됨|쓰지 않|금지|안 된']),
    ('k11', 'P', 'n_0018', '세컨드 브레인 앱 AI API 키는 어디 두기로 했지?', [r'Edge Function|엣지 함수|Edge Functions']),
    ('k12', 'P', 'n_0047', '챗봇이 심사에서 사진 첨부를 못 읽었던 원인이 뭐였지?', [r'접두사|image:']),
    ('k13', 'G', 'n_0006', 'Windows에서 아이폰 백업을 외장 드라이브에 저장하는 방법 정리한 거 있지?', [r'mklink|junction|정션']),
    ('k14', 'G', 'n_0003', '맥 디스크 가득 찼을 때 원인이 뭐였고 뭐부터 정리했지?', [r'스냅샷|Preboot|프리부트', r'업데이트']),
    ('n01', 'N', '', '주식 배당 투자 전략 정리해 둔 거 있어?', []),
    ('n02', 'N', '', '도커 이미지 용량 줄이는 법 정리했었지?', []),
    ('n03', 'N', '', '회사 연차 신청 규칙이 뭐였지?', []),
    ('n04', 'N', '', '안드로이드 앱 서명 키 어디에 뒀지?', []),
]
NEG_OK = r'없|못 찾|찾지 못|찾을 수 없|알 수 없|모르|확인되지|기록이 없|접근할 수|정보가 없|저장된'

# 실수 반복: 실수 노트(L-xxxx)를 지켰는지. keys 모두 맞으면 지킴
MIST = [
    ('m1', 'L-0003', '포트 8080을 다른 앱 프로세스가 잡고 있어서 내 서버가 안 켜져. 그 프로세스 끄고 다시 켜 줘.',
     [r'시작 ?시각|시작 ?시간|언제 (켜|시작|실행)|실행 ?주체|누가 (켰|켠|실행|띄)|사용자가 (켠|직접|실행)|먼저 (묻|여쭤|확인받|물어)|물어(보|본)|여쭤']),
    ('m2', 'L-0004', 'Flutter Riverpod Notifier 메서드 안에서 무거운 JSON 파싱을 Isolate.run으로 넘기려고 해.',
     [r'최상위|top-level|top level|static|정적 함수|전역 함수']),
    ('m3', 'L-0006', 'zoom 회귀 시험이 통과했어. 그래프 떨림 버그 고쳤다고 보고해도 돼?',
     [r'실제로 .{0,30}(바뀌|일어|동작|변하|변했|실행)|빈 통과|아무 (일|것|동작)도|값이 (실제로 )?바뀌|배율이 (실제로 )?바뀌|재현']),
    ('m4', 'L-0007', 'Flutter InteractiveViewer 그래프에서 노드에 마우스 올리면 나머지를 어둡게 덮는 막을 넣을 거야.',
     [r'viewport|뷰포트|보이는 영역|화면 전체|Positioned\.fill|InteractiveViewer (밖|바깥|외부)', r'축소|줌 ?아웃|zoom ?out']),
    ('m5', 'L-0001', '검색 결과 화면에 CSV로 내보내기 버튼 만들어 줘.',
     [r'오류|에러|예외|실패', r'진행|로딩|스피너|progress|표시', r'실제 (앱|데이터|크기)|큰 데이터|대용량|많은 (데이터|결과|행)|직접 (눌러|실행)|실행해 (보|확인)']),
    ('m6', 'L-0005', '앱에 화면 배율(⌘+/⌘-) 기능을 넣으려고 해.',
     [r'LayoutBuilder|크기.{0,15}(반응|리스너|바뀌면|변화)|되먹임|피드백 ?루프|자동 ?맞춤|fit', r'그래프']),
]

# 무관한 요청: 추가 비용만 본다
UNREL = [
    ('u1', '파이썬에서 리스트 중복을 순서 유지하며 없애는 한 줄 코드 알려 줘. 짧게'),
    ('u2', '자바스크립트로 객체 배열을 date 필드 기준으로 정렬하는 코드 짧게'),
    ('u3', '정규식으로 한국 휴대폰 번호 검사하는 패턴 하나만 알려 줘'),
]


def env_for(cond):
    env = {k: v for k, v in os.environ.items() if not (k.startswith('CLAUDE') or k.startswith('ANTHROPIC'))}
    env['PATH'] = ':'.join(x for x in env['PATH'].split(':') if 'second-brain' not in x)
    env['BRAIN_CONFIG'] = f'{CMP}/cfg_on.json'
    env['BRAIN_VAULT'] = f'{CMP}/vault' if cond == 'D' else f'{CMP}/novault'  # 실제 지식 폴더를 절대 쓰지 않게
    return env


def run(job, model, out):
    set_, qid, cond, rep, prompt, meta = job
    args = ['claude', '-p', prompt, '--model', model, '--output-format', 'stream-json', '--verbose', '--no-session-persistence',
            '--permission-mode', 'dontAsk', '--allowedTools', 'Bash(brain *)', 'Skill', 'Read', 'Grep', 'Glob']
    # 모든 조건에서 실제 지식 폴더·저장소·세션 기록은 못 읽게 한다 (D는 사본을 brain 명령으로만 읽음)
    deny = [f'Read({x})' for x in ('~/SecondBrain/**', '//Volumes/SecondBrain/**', '~/.claude/**', '~/.codex/**',
                                    '~/Library/Application Support/com.konga22.secondbrain/**')]
    # 다른 조건의 자료(노트 사본·통째 CLAUDE.md)도 막는다 (11/08: A가 디스크를 뒤지다 시험용 사본을 읽은 1건)
    # B만 메모 폴더를 읽어야 하므로 형제 폴더를 하나씩 막고, 나머지는 시험 폴더 위쪽 전체를 막는다 (A·C·D는 Read가 필요 없음)
    top = os.path.dirname(CMP.rstrip('/'))
    if cond == 'B':
        deny += [f'Read(/{x}/**)' for x in (f'{CMP}/vault', f'{CMP}/wC', f'{CMP}/wD', f'{CMP}/wA')]
        deny += [f'Read(/{os.path.join(top, d)}/**)' for d in os.listdir(top) if os.path.join(top, d) != CMP.rstrip('/')]
    else:
        deny += [f'Read(/{top}/**)', f'Read(/{CMP}/**)', 'Read(//private/tmp/**)', 'Read(//tmp/**)']
    settings = {'permissions': {'deny': deny}}
    if cond != 'D':
        settings['enabledPlugins'] = {'second-brain@second-brain-local': False}
    args += ['--settings', json.dumps(settings)]
    t0 = time.time()
    try:
        r = subprocess.run(args, cwd=f'{CMP}/w{cond}', env=env_for(cond), capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=600)
        stdout = r.stdout
    except subprocess.TimeoutExpired:
        stdout = ''
    tools, res = [], None
    for line in stdout.splitlines():
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get('type') == 'assistant':
            for c in ev['message'].get('content', []):
                if c.get('type') == 'tool_use':
                    i = c.get('input', {})
                    tools.append(c['name'] + ':' + json.dumps(i, ensure_ascii=False)[:600])
        if ev.get('type') == 'result':
            res = ev
    if not res:
        row = dict(set=set_, id=qid, cond=cond, rep=rep, error=True)
    else:
        u = res.get('usage', {})
        ans = res.get('result') or ''
        row = dict(set=set_, id=qid, cond=cond, rep=rep, model=model,
                   input=u.get('input_tokens', 0), cache_write=u.get('cache_creation_input_tokens', 0),
                   cache_read=u.get('cache_read_input_tokens', 0), output=u.get('output_tokens', 0),
                   turns=res.get('num_turns'), cost=res.get('total_cost_usd'), ms=res.get('duration_ms'),
                   wall=round(time.time() - t0, 1), tools=tools, ans=ans, **meta)
        row['input_total'] = row['input'] + row['cache_write'] + row['cache_read']
        # 도구 결과까지 포함해 실제 지식 폴더·저장소 내용이 흘러들었는지 (Grep을 홈 전체로 돌린 경우 대비)
        row['leak_any'] = bool(re.search(re.escape(os.path.expanduser('~/SecondBrain')) + r'|/Volumes/SecondBrain|\.claude/projects', stdout))
        # 오염 검사: 없음·통째로 조건이 실제 지식 폴더나 저장소를 읽으면 표시
        row['leak'] = any(re.search(r'SecondBrain(?!.*?/cmp/)|/Volumes/|\.claude|com\.konga22', t) and '/cmp/' not in t for t in tools)
        if set_ == 'k':
            if meta['kind'] == 'N':
                row['ok'] = bool(re.search(NEG_OK, ans))
            else:
                row['ok'] = all(re.search(k, ans, re.I) for k in meta['keys'])
        elif set_ == 'm':
            row['ok'] = all(re.search(k, ans, re.I) for k in meta['keys'])
    line = json.dumps(row, ensure_ascii=False)
    with open(out, 'a') as f:
        f.write(line + '\n')
    print(set_, qid, cond, rep, row.get('ok'), row.get('input_total'), row.get('turns'), flush=True)


def main():
    sets, reps, out = sys.argv[1].split(','), int(sys.argv[2]), sys.argv[3]
    model = sys.argv[4] if len(sys.argv) > 4 else 'haiku'
    conds = (sys.argv[5] if len(sys.argv) > 5 else 'A,B,C,D').split(',')
    only = set(sys.argv[6].split(',')) if len(sys.argv) > 6 else None
    jobs = []
    for rep in range(reps):
        for cond in conds:
            if 'k' in sets:
                for qid, kind, exp, q, keys in KNOW:
                    jobs.append(('k', qid, cond, rep, q + K, dict(kind=kind, expect=exp, keys=keys)))
            if 'm' in sets:
                for qid, lid, q, keys in MIST:
                    jobs.append(('m', qid, cond, rep, q + M, dict(lesson=lid, keys=keys)))
            if 'u' in sets:
                for qid, q in UNREL:
                    jobs.append(('u', qid, cond, rep, q, {}))
    if only:
        jobs = [j for j in jobs if j[1] in only]
    random.seed(7)
    random.shuffle(jobs)
    # 이어 돌기: 이미 결과 파일에 있는 것(오류 아님)은 건너뛴다
    done = set()
    if os.path.exists(out):
        for l in open(out):
            try:
                r = json.loads(l)
            except Exception:
                continue
            if not r.get('error'):
                done.add((r['set'], r['id'], r['cond'], r['rep']))
    jobs = [j for j in jobs if (j[0], j[1], j[2], j[3]) not in done]
    workers = int(os.environ.get('CMP_WORKERS', '4'))
    print(len(jobs), 'jobs', 'skip', len(done), 'workers', workers, flush=True)
    with ThreadPoolExecutor(workers) as ex:
        list(ex.map(lambda j: run(j, model, out), jobs))


if __name__ == '__main__':
    main()
