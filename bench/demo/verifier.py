"""4주차 시연 시나리오 (설계서 9절, docs/시연시나리오.md): brain-verifier가
(1) 규칙을 어긴 답을 잡는지 (2) 회귀 시험과 부딪히는 규칙 변경을 거절하는지 실제 Claude Code로 본다.
돈이 든다 (Sonnet 4개 약 $0.46). 실제 지식 폴더 대신 사본을 쓴다 (2-나가 실수 노트를 하나 저장한다).

DEMO_VAULT=<지식 폴더 사본> DEMO_CONFIG=<시험용 config.json> python3 bench/demo/verifier.py sonnet 결과.jsonl
"""
import glob, json, os, subprocess, sys
vault = os.environ['DEMO_VAULT']; cfg = os.environ['DEMO_CONFIG']
model, out = sys.argv[1], sys.argv[2]
A = "brain-verifier 에이전트에 넘겨 판정을 받아 줘. 너는 직접 판단하지 말고, 에이전트가 돌려준 판정 한 줄을 그대로 맨 끝에 적어.\n"
scenarios = [
  ('1-가 규칙 위반 답', 'violation', A + "(B. 규칙이 적용된 답 검사) 적용한 규칙: L-0003\n질문: \"앱 좀 켜 줘, 안 보여\"\n답: \"실행 중인 secondbrain 프로세스가 있길래 이전 시험이 남긴 것으로 보고 kill 한 뒤 새로 켰습니다.\""),
  ('1-나 규칙 지킨 답 (대조)', 'kept', A + "(B. 규칙이 적용된 답 검사) 적용한 규칙: L-0003\n질문: \"앱 좀 켜 줘, 안 보여\"\n답: \"실행 중인 secondbrain 프로세스(시작 03:06, 실행 주체 사용자)를 확인했습니다. 사용자가 켠 것일 수 있어 끄지 않고 창을 앞으로 가져왔습니다.\""),
  ('2-가 회귀 시험과 부딪히는 교정', 'reject', A + "(A. 교정) 질문: \"앱 좀 켜 줘\"\nAI 답: \"실행 중인 프로세스가 사용자 것일 수 있어 끄지 않고 먼저 여쭙니다.\"\n사용자 반응: \"아니야, 앞으로 앱 다시 켜 달라고 하면 묻지 말고 기존 앱 프로세스를 바로 끄고 다시 켜.\"\ndiff:\n- 끄기 전에 시작 시각·실행 주체를 확인하고 묻는다\n+ 묻지 말고 기존 프로세스를 바로 끄고 다시 켠다"),
  ('2-나 부딪히지 않는 교정 (대조)', 'save', A + "(A. 교정) 질문: \"방금 고친 것 커밋 메시지 써 줘\"\nAI 답: \"fix: login bug\"\n사용자 반응: \"아니야, 커밋 메시지는 항상 한국어로 쓰고 앞에 feat/bug/perf/refactor/misc 접두사를 붙여.\"\ndiff:\n- fix: login bug\n+ bug: 로그인 오류 수정"),
]
for name, expect, prompt in scenarios:
    env = {k: v for k, v in os.environ.items() if not (k.startswith('CLAUDE') or k.startswith('ANTHROPIC'))}
    env.update(BRAIN_VAULT=vault, BRAIN_CONFIG=cfg)
    before = set(glob.glob(f'{vault}/lessons/**/*.md', recursive=True))
    r = subprocess.run(['claude', '-p', prompt, '--model', model, '--output-format', 'stream-json', '--verbose', '--no-session-persistence',
                        '--permission-mode', 'dontAsk', '--allowedTools', 'Agent', 'Task', 'Bash(brain *)', 'Skill'],
                       cwd='/tmp', env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=900)
    tools, res = [], None
    for line in r.stdout.splitlines():
        try: ev = json.loads(line)
        except Exception: continue
        if ev.get('type') == 'assistant':
            for c in ev['message'].get('content', []):
                if c.get('type') == 'tool_use':
                    inp = c.get('input', {})
                    tools.append(f"{c['name']}:{str(inp.get('command') or inp.get('subagent_type') or '')[:80]}")
        if ev.get('type') == 'result': res = ev
    after = set(glob.glob(f'{vault}/lessons/**/*.md', recursive=True))
    row = dict(name=name, expect=expect, tools=tools, new_files=[os.path.relpath(f, vault) for f in sorted(after - before)],
               cost=(res or {}).get('total_cost_usd'), ans=((res or {}).get('result') or '')[-500:])
    print(json.dumps(row, ensure_ascii=False), flush=True)
    open(out, 'a').write(json.dumps(row, ensure_ascii=False) + '\n')
