# 세컨드 브레인 플랫폼

md 노트와 SQLite FTS5 색인으로 내 지식을 기기에 쌓고, Claude Code·Codex가 brain CLI로 바로 찾아 쓰는 macOS 데스크톱 앱. 웹은 홍보 페이지(Astro)만 둔다.

- 양윤모 교수님 기말 프로젝트 · 김민상 (대림대 3학년 2반) · 마감 2026-12-08
- 현재 단계: 1주차(11/06 ~ 11/12) — 앱 뼈대와 SQLite FTS5 확인

## 문서

| 문서 | 내용 |
|---|---|
| [docs/설계서.md](docs/설계서.md) | 개발 기준. 구현이 바뀌면 여기부터 고친다 |
| [기말프로젝트_기획안_김민상.pdf](기말프로젝트_기획안_김민상.pdf) | 교수님께 제출한 기획안 v1.0 (원본: `docs/기획안_원본/`) |
| [docs/주간보고/](docs/주간보고/README.md) | 7일마다 내는 주간 보고, 작업일지, 피드백 기록 |
| [docs/참고레포_조사.md](docs/참고레포_조사.md) | 참고 오픈소스 후보와 유사 프로젝트 |

## 실행

앱을 빌드하기 전에 brain CLI를 앱 자산에 넣는다.

```bash
bash tool/build_brain.sh
```

```bash
flutter run -d macos
```

Supabase까지 붙여 실행하려면 `env/supabase.example.json`을 `env/supabase.json`으로 복사해 프로젝트 주소와 공개 키를 넣고 아래처럼 실행한다. `env/supabase.json`은 저장소에 올리지 않는다.

```bash
flutter run -d macos --dart-define-from-file=env/supabase.json
```

```bash
flutter test
```

```bash
cd packages/brain_core && dart test
```

```bash
cd packages/brain_cli && dart run bin/brain.dart doctor
```

`brain` 실행 파일은 `cd packages/brain_cli && dart build cli`로 만든다 (`build/cli/macos_arm64/bundle/`에 실행 파일과 `libsqlite3.dylib`가 함께 나온다).

## 폴더

설계서 8절 기준이다. `lib/`·`packages/`는 만들었고, 나머지는 개발하면서 하나씩 만든다.

```text
lib/           # Flutter macOS 앱
packages/      # brain_core (앱·CLI 공통), brain_cli (brain 명령)
integrations/  # Claude Code 플러그인(스킬·훅) 원본, 개발 설치는 bash integrations/claude-code/install.sh
web/           # 홍보 페이지 (Astro)
supabase/      # Edge Functions (AI 게이트웨이), DB 마이그레이션
docs/          # 설계서, 기획안, 주간 보고
```

## 보고서 다시 만들기

```bash
bash docs/주간보고/make.sh 00_기점
```

처음 실행하면 `docs/기획안_원본/`에서 `npm install`을 한 번 한다.
