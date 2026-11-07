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
