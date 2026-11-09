// 첫 화면 "뇌 그래프": 샘플 데이터만 쓴다(사용자 지식 아님). 앱 그래프와 같은 힘 배치 방식(force-graph, MIT).
import ForceGraph from 'force-graph';

type Node = { id: string; topic: string; hub?: boolean };
type Link = { source: string; target: string; suggested?: boolean };

const topics: Record<string, string[]> = {
  결제: ['웹훅 재시도 규칙', '환불 처리 순서', '결제 테스트 키', '영수증 메일'],
  배포: ['목요일 배포 규칙', '롤백 절차', '빌드 캐시 정리', '환경 변수 위치'],
  검색: ['한글 2글자 색인', '조사 떼기', '느슨하게 채우기', '검색 시험 질문'],
  'AI 도구': ['Claude Code 플러그인', '훅으로 규칙 넣기', '세션 기록 정리', '토큰 아끼기'],
  '맥 관리': ['디스크 정리 순서', 'Xcode 설치', 'USB 개발 환경'],
  '실수 노트': ['커밋은 허락 받고', '앱 끄기 전 확인', '배율 바꾼 뒤 확인'],
};

const nodes: Node[] = [];
const links: Link[] = [];
for (const [topic, titles] of Object.entries(topics)) {
  titles.forEach((title, i) => {
    nodes.push({ id: title, topic, hub: i === 0 });
    if (i > 0) links.push({ source: titles[0], target: title });
  });
}
// 주제를 넘는 연결 몇 개 (추천 연결은 흐리게)
[
  ['웹훅 재시도 규칙', '롤백 절차', true],
  ['한글 2글자 색인', '토큰 아끼기', false],
  ['Claude Code 플러그인', '훅으로 규칙 넣기', false],
  ['커밋은 허락 받고', '목요일 배포 규칙', true],
  ['USB 개발 환경', '빌드 캐시 정리', true],
  ['세션 기록 정리', '검색 시험 질문', true],
].forEach(([a, b, s]) => links.push({ source: a as string, target: b as string, suggested: s as boolean }));

export function mountGraph(el: HTMLElement) {
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const graph = new ForceGraph(el)
    .graphData({ nodes, links })
    .backgroundColor('rgba(0,0,0,0)')
    .nodeRelSize(4)
    .nodeVal((n: Node) => (n.hub ? 3 : 1.2))
    .linkColor((l: Link) => (l.suggested ? 'rgba(214,211,232,0.25)' : 'rgba(167,139,250,0.55)'))
    .linkLineDash((l: Link) => (l.suggested ? [3, 3] : null))
    .linkWidth(1)
    .enableZoomInteraction(false)
    // 동작 줄이기: 움직임 없이 배치를 미리 다 계산해 멈춘 그림으로 보여 준다 (0번 돌리면 시작 위치에 뭉친 채 크게 확대됨)
    .warmupTicks(reduce ? 200 : 0)
    .cooldownTicks(reduce ? 0 : 200)
    .nodeCanvasObject((n: any, ctx: CanvasRenderingContext2D, scale: number) => {
      // 첫 프레임에는 배치 전이라 x·y가 없을 수 있다. 그대로 그리면 createRadialGradient가 예외를 내고
      // force-graph의 그리기 반복이 멈춰 그래프가 끝까지 안 보인다(11/09 휴대폰에서 발견, 기능검토 K-14).
      if (!Number.isFinite(n.x) || !Number.isFinite(n.y) || !Number.isFinite(scale) || scale <= 0) return;
      const r = n.hub ? 6 : 4;
      const glow = ctx.createRadialGradient(n.x, n.y, 0, n.x, n.y, r * 3);
      glow.addColorStop(0, 'rgba(228,225,245,0.35)');
      glow.addColorStop(1, 'rgba(228,225,245,0)');
      ctx.fillStyle = glow;
      ctx.beginPath();
      ctx.arc(n.x, n.y, r * 3, 0, 2 * Math.PI);
      ctx.fill();
      ctx.fillStyle = n.hub ? '#ffffff' : '#e4e1f5';
      ctx.beginPath();
      ctx.arc(n.x, n.y, r, 0, 2 * Math.PI);
      ctx.fill();
      if (n.hub || scale > 1.6) {
        ctx.font = `500 ${11 / scale}px Pretendard Variable, sans-serif`;
        ctx.textAlign = 'center';
        ctx.fillStyle = 'rgba(234,231,247,0.85)';
        ctx.fillText(n.hub ? n.topic : n.id, n.x, n.y + r + 12 / scale);
      }
    })
    .nodeLabel((n: Node) => `${n.topic} · ${n.id}`);
  const resize = () => graph.width(el.clientWidth).height(el.clientHeight);
  resize();
  new ResizeObserver(resize).observe(el);
  graph.onEngineStop(() => graph.zoomToFit(400, 30));
}
