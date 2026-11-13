# Claude Code 연동 묶음

세컨드 브레인 앱이 Claude Code에 설치하는 플러그인의 원본이다 (설계서 5.2).

| 이 폴더 | 설치되는 위치 (`~/Library/Application Support/com.konga22.secondbrain/claude-code/`) |
|---|---|
| `marketplace.json` | `.claude-plugin/marketplace.json` (로컬 마켓플레이스 `second-brain-local`) |
| `plugin.json` | `second-brain/.claude-plugin/plugin.json` |
| `hooks.json` | `second-brain/hooks/hooks.json` (SessionStart: 온보딩 요약, UserPromptSubmit: 맞는 실수 노트·노트, PreToolUse: `brain` 명령만(`"if": "Bash(brain *)"`, 다른 Bash 호출에는 `brain`을 띄우지 않음), SessionEnd: 저장 안 한 세션 표시) |
| `skills/second-brain/` | `second-brain/skills/second-brain/` (찾고 읽기) |
| `skills/brain-save/` | `second-brain/skills/brain-save/` (대화 → 지식) |
| (빌드 결과) `brain`, `libsqlite3.dylib` | `second-brain/bin/brain`, `second-brain/lib/libsqlite3.dylib` |

- 플러그인의 `bin/`은 플러그인이 켜져 있는 동안 Claude Code의 Bash 도구 PATH에 들어간다. 그래서 스킬은 `brain`을 그냥 부른다.
- 설치: `claude plugin marketplace add <위치>` → `claude plugin install second-brain@second-brain-local`.
- 해제: `claude plugin uninstall second-brain@second-brain-local` → `claude plugin marketplace remove second-brain-local`.
- 개발 중에는 `bash integrations/claude-code/install.sh`로 같은 설치를 한다.
