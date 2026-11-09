# 홍보 페이지 (web/)

세컨드 브레인 홍보용 정적 사이트 (설계서 3.1). 앱 기능을 돌리지 않고 지식 데이터도 다루지 않는다.

- Astro 5.18.2 + Tailwind 4.3.5 + force-graph 1.52.0 + Pretendard 1.3.9 (버전 고정, 라이선스는 설계서 11절)
- 소스: `src/pages/index.astro`(내용), `src/styles/global.css`(앱 색), `src/scripts/graph.ts`(샘플 뇌 그래프)
- 숫자는 개발 중 실측(docs/토큰분석.md, 설계서 5.8), 요금은 추천안(docs/요금제분석.md, 가안)

## 실행

```bash
cd web
npm install
npx astro dev        # http://localhost:4321
npx astro build      # dist/ 에 정적 파일
```

USB 볼륨에 공간이 없을 때(2026-11-07 기준 남은 공간 약 220MB)는 내장 디스크 작업 폴더에서 돌린다:

```bash
DEV=~/Library/Caches/com.konga22.secondbrain/web-dev
rsync -a --delete --exclude node_modules --exclude dist --exclude .astro web/ "$DEV/"
(cd "$DEV" && npm install && npx astro build && npx astro preview)
```

## 배포 (Cloudflare Pages, 2026-11-09)

- 주소: https://second-brain-cvj.pages.dev/ (프로젝트 `second-brain`, 사용자 Cloudflare 계정)
- 저장소를 연결하지 않고 빌드한 `dist/`만 올린다. 비공개 저장소 코드는 Cloudflare로 가지 않는다.
- 로그인은 배포에 필요한 권한만 준다. 사용 통계 전송은 끈다.

```bash
DEV=~/Library/Caches/com.konga22.secondbrain/web-dev
rsync -a --delete --exclude node_modules --exclude dist --exclude .astro web/ "$DEV/"
cd "$DEV" && npx astro build
export WRANGLER_SEND_METRICS=false
npx --yes wrangler@4 login --scopes account:read user:read pages:write   # 처음 한 번, 브라우저에서 [Allow]
npx --yes wrangler@4 pages deploy dist --project-name second-brain --branch main --commit-dirty=true
```

- 11/09 첫 로그인 때 한 번 `request_forbidden`이 나왔다. 다시 띄우자 됐다(원인 모름).
- 설치 파일(.dmg)은 Pages 파일 하나 한도(25MiB)를 넘을 수 있어 여기에 올리지 않는다.
