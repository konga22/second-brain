"""토큰 실측 (docs/토큰분석.md): claude -p를 조건별로 돌려 usage를 모은다. 돈이 든다(Haiku 한 번 약 $0.003~0.009).

TOKEN_VAULT=<지식 폴더 사본> python3 bench/token/live.py <이름> <설정 json|-> <플러그인 on|off> <프롬프트>
- 실제 지식 폴더 대신 사본을 쓴다 (세션 끝 훅이 '저장 안 한 세션'으로 적지 않게)
- 설정 json: onboardingOff·autoCaptureOff로 세션 시작 안내를 켜고 끈다 (사용자 설정은 건드리지 않음)
- 결과는 이 폴더 results.jsonl에 한 줄씩 쌓인다
"""
import json, os, subprocess, sys
name, cfg, plugin, prompt = sys.argv[1:5]
sp = os.path.dirname(os.path.abspath(__file__))
env = {k: v for k, v in os.environ.items() if not (k.startswith('CLAUDE') or k.startswith('ANTHROPIC'))}
env['BRAIN_VAULT'] = os.environ['TOKEN_VAULT']  # 실제 지식 폴더를 건드리지 않게 사본 (없으면 멈춤)
if cfg != '-': env['BRAIN_CONFIG'] = cfg
args = ['claude', '-p', prompt, '--model', 'haiku', '--output-format', 'stream-json', '--verbose', '--no-session-persistence',
        '--permission-mode', 'dontAsk', '--allowedTools', 'Bash(brain *)', 'Skill', 'Read', 'Grep', 'Glob']
if plugin == 'off':
    args += ['--settings', json.dumps({'enabledPlugins': {'second-brain@second-brain-local': False}})]
r = subprocess.run(args, cwd=os.environ.get('TOKEN_WORKDIR', '/tmp'), env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=600)
tools = []
d = None
for line in r.stdout.splitlines():
    try:
        ev = json.loads(line)
    except Exception:
        continue
    if ev.get('type') == 'assistant':
        for c in ev.get('message', {}).get('content', []):
            if c.get('type') == 'tool_use':
                inp = c.get('input', {})
                tools.append(c['name'] + ':' + str(inp.get('command') or inp.get('file_path') or inp.get('skill') or inp.get('pattern') or '')[:70])
    if ev.get('type') == 'result':
        d = ev
if d is None:
    print(name, 'ERROR', r.stdout[-500:], r.stderr[-500:]); sys.exit(1)
u = d.get('usage', {})
inp = u.get('input_tokens', 0) + u.get('cache_creation_input_tokens', 0) + u.get('cache_read_input_tokens', 0)
row = dict(name=name, input_total=inp, input=u.get('input_tokens'), cache_write=u.get('cache_creation_input_tokens'),
           cache_read=u.get('cache_read_input_tokens'), output=u.get('output_tokens'), turns=d.get('num_turns'),
           cost=d.get('total_cost_usd'), tools=tools, result=(d.get('result') or '')[:300].replace('\n', ' '))
print(json.dumps(row, ensure_ascii=False))
with open(os.path.join(sp, 'results.jsonl'), 'a') as f: f.write(json.dumps(row, ensure_ascii=False) + '\n')
