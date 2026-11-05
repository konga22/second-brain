// 세컨드 브레인 시안 — 모의 데이터와 화면 전환만 있다. 서버·저장 없음.
// 주소 뒤 #screen=home&theme=dark&view=graph&cmdk=1&chat=corrected&connect=done 로 상태를 바로 열 수 있다(스크린샷용).

// ---------- 아이콘 (Lucide 모양을 따른 시안용 SVG) ----------
const ICON = {
  graph: '<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><line x1="8.59" x2="15.42" y1="13.51" y2="17.49"/><line x1="15.41" x2="8.59" y1="6.51" y2="10.49"/>',
  note: '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>',
  chat: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
  lesson: '<path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5"/><path d="M9 18h6"/><path d="M10 22h4"/>',
  todo: '<path d="m9 11 3 3L22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/>',
  import: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/>',
  plug: '<path d="M12 22v-5"/><path d="M9 8V2"/><path d="M15 8V2"/><path d="M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z"/>',
  settings: '<path d="M20 7h-9"/><path d="M14 17H5"/><circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/>',
  search: '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
  list: '<path d="M8 6h13"/><path d="M8 12h13"/><path d="M8 18h13"/><path d="M3 6h.01"/><path d="M3 12h.01"/><path d="M3 18h.01"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
  alert: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
  file: '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>',
  send: '<path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/>',
  thumbs: '<path d="M7 10v12"/><path d="M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z"/>',
  flask: '<path d="M10 2v7.31"/><path d="M14 9.3V1.99"/><path d="M8.5 2h7"/><path d="M14 9.3a6.5 6.5 0 1 1-4 0"/><path d="M5.52 16h12.96"/>',
  terminal: '<polyline points="4 17 10 11 4 5"/><line x1="12" x2="20" y1="19" y2="19"/>',
  shield: '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>',
  plus: '<path d="M5 12h14"/><path d="M12 5v14"/>',
  minus: '<path d="M5 12h14"/>',
  panel: '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M15 3v18"/>',
  folder: '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
  brain: '<path d="M12 5a3 3 0 1 0-5.997.125 4 4 0 0 0-2.526 5.77 4 4 0 0 0 .556 6.588A4 4 0 1 0 12 18Z"/><path d="M12 5a3 3 0 1 1 5.997.125 4 4 0 0 1 2.526 5.77 4 4 0 0 1-.556 6.588A4 4 0 1 1 12 18Z"/><path d="M12 5v13"/>',
  clock: '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
  board: '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M8 7v7"/><path d="M12 7v4"/><path d="M16 7v9"/>',
  chevright: '<path d="m9 18 6-6-6-6"/>',
  chevdown: '<path d="m6 9 6 6 6-6"/>',
  listtree: '<path d="M21 12h-8"/><path d="M21 6H8"/><path d="M21 18h-8"/><path d="M3 6v4c0 1.1.9 2 2 2h3"/><path d="M3 10v6c0 1.1.9 2 2 2h3"/>',
  focus: '<circle cx="12" cy="12" r="3"/><circle cx="12" cy="12" r="8"/>',
  arrow: '<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>',
};
const icon = (name, size = 16) =>
  `<svg class="ic" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON[name]}</svg>`;

// ---------- 모의 데이터 ----------
const TOPICS = [
  { id: 'pay', name: '결제' },
  { id: 'server', name: '서버' },
  { id: 'flutter', name: 'Flutter' },
  { id: 'search', name: '검색' },
  { id: 'ai', name: 'AI 연동' },
  { id: 'project', name: '기말 프로젝트' },
];
const NOTES = [
  { id: 'n_0042', t: '결제 웹훅 재시도 규칙', topic: 'pay', s: '웹훅 실패 시 3번까지 간격을 늘려 재시도한다', src: 'chat', up: '11/21' },
  { id: 'n_0051', t: '웹훅 서명 검증', topic: 'pay', s: '받은 웹훅은 서명 헤더로 먼저 진짜인지 확인한다', src: 'import', up: '11/18', lint: ['info', '중복 후보 · n_0042'] },
  { id: 'n_0063', t: '토스 결제 테스트 키', topic: 'pay', s: '테스트 키는 .env.test에만 두고 실제 키와 섞지 않는다', src: 'manual', up: '11/17' },
  { id: 'n_0070', t: '환불 처리 흐름', topic: 'pay', s: '부분 환불은 원 결제 id로 묶어서 기록한다', src: 'session', up: '11/12', lint: ['warn', '죽은 링크 1'] },
  { id: 'n_0077', t: '결제 실패 알림', topic: 'pay', s: '3번 모두 실패하면 운영 채널로 알림을 보낸다', src: 'chat', up: '11/21' },
  { id: 'n_0012', t: 'Supabase Edge Functions', topic: 'server', s: 'Deno로 돌고, 비밀값은 함수 환경변수에만 둔다', src: 'manual', up: '11/05' },
  { id: 'n_0018', t: 'JWT 확인 방법', topic: 'server', s: '모든 함수 첫 줄에서 로그인 토큰을 확인한다', src: 'import', up: '11/09' },
  { id: 'n_0025', t: '사용량 표(usage)', topic: 'server', s: '월별 ai_calls만 센다. 질문 내용은 저장하지 않는다', src: 'manual', up: '11/05' },
  { id: 'n_0031', t: '로그에 본문 남기지 않기', topic: 'server', s: '게이트웨이는 요청 본문을 로그에 쓰지 않는다', src: 'manual', up: '11/05' },
  { id: 'n_0101', t: 'Riverpod 상태 관리', topic: 'flutter', s: '화면 상태는 Provider 하나에 모은다', src: 'session', up: '11/14' },
  { id: 'n_0104', t: 'go_router 경로', topic: 'flutter', s: '화면 10개 경로를 한 파일에서 관리한다', src: 'session', up: '11/14' },
  { id: 'n_0110', t: 'CustomPainter 그래프', topic: 'flutter', s: 'Barnes–Hut으로 밀어내는 힘을 근사한다', src: 'chat', up: '11/20' },
  { id: 'n_0115', t: 'macOS 창 설정', topic: 'flutter', s: '제목 표시줄을 숨기고 최소 크기를 1024로 둔다', src: 'session', up: '11/13' },
  { id: 'n_0119', t: '한글 입력 확인', topic: 'flutter', s: '조합 중인 글자가 두 번 들어가지 않는지 시험한다', src: 'manual', up: '11/07', lint: ['info', '고아 노트'] },
  { id: 'n_0201', t: 'FTS5 contentless 색인', topic: 'search', s: '원문 사본 없이 색인만 둔다. snippet() 대신 요약 줄', src: 'manual', up: '11/05' },
  { id: 'n_0204', t: '한글 2글자 분할', topic: 'search', s: '공백을 무시하고 2글자씩 잘라 띄어쓰기와 상관없이 찾는다', src: 'manual', up: '11/05' },
  { id: 'n_0207', t: 'BM25 가중치', topic: 'search', s: '제목 3배, 본문 1배', src: 'manual', up: '11/05' },
  { id: 'n_0210', t: 'brain bench 질문 세트', topic: 'search', s: '질문 30개로 recall@5와 MRR을 잰다', src: 'manual', up: '11/06' },
  { id: 'n_0301', t: 'brain CLI 명령', topic: 'ai', s: 'find·show·add·write·lesson·hook·index·doctor·lint·bench', src: 'manual', up: '11/05' },
  { id: 'n_0305', t: 'Claude Code 훅', topic: 'ai', s: 'SessionStart·UserPromptSubmit·SessionEnd 세 개만 쓴다', src: 'import', up: '11/05' },
  { id: 'n_0308', t: 'Codex 훅 승인', topic: 'ai', s: 'Codex는 /hooks에서 사용자가 승인해야 훅이 돈다', src: 'import', up: '11/05' },
  { id: 'n_0311', t: 'Agent Skills 표준', topic: 'ai', s: 'SKILL.md 한 벌로 Claude Code·Codex 둘 다', src: 'import', up: '11/05' },
  { id: 'n_0315', t: '프롬프트 주입 경계', topic: 'ai', s: 'show 출력에 데이터 경계를 붙이고 노트 속 지시는 따르지 않는다', src: 'manual', up: '11/05' },
  { id: 'n_0401', t: '설계서 v1.3', topic: 'project', s: '원본·파생 분리, 공백 무시 분할, 회귀 시험', src: 'manual', up: '11/05' },
  { id: 'n_0404', t: '주간 보고 일정', topic: 'project', s: '11/12 · 11/19 · 11/26 · 12/03 · 12/08', src: 'manual', up: '11/05' },
  { id: 'n_0407', t: '교수님 피드백 9건', topic: 'project', s: '임베딩 불필요, CLI, 검증 에이전트 등', src: 'chat', up: '11/05' },
  { id: 'n_0410', t: '기획안 v1.0', topic: 'project', s: '11/05 13:59 제출', src: 'manual', up: '11/05' },
  { id: 'n_0413', t: '시연 시나리오', topic: 'project', s: '교정 → 다음 질문에 반영 → 규칙 위반은 검증에서 걸림', src: 'manual', up: '11/06' },
];
const LINKS = [
  ['n_0042', 'n_0063', 'manual'], ['n_0042', 'n_0051', 'manual'], ['n_0042', 'n_0077', 'manual'],
  ['n_0063', 'n_0070', 'manual'], ['n_0070', 'n_0077', 'manual'], ['n_0042', 'n_0012', 'suggested'],
  ['n_0012', 'n_0018', 'manual'], ['n_0012', 'n_0025', 'manual'], ['n_0012', 'n_0031', 'manual'], ['n_0031', 'n_0042', 'suggested'],
  ['n_0101', 'n_0104', 'manual'], ['n_0110', 'n_0115', 'manual'], ['n_0119', 'n_0115', 'suggested'], ['n_0101', 'n_0110', 'manual'],
  ['n_0201', 'n_0204', 'manual'], ['n_0204', 'n_0207', 'manual'], ['n_0207', 'n_0210', 'manual'], ['n_0201', 'n_0210', 'manual'],
  ['n_0301', 'n_0201', 'manual'], ['n_0301', 'n_0305', 'manual'], ['n_0305', 'n_0308', 'manual'], ['n_0311', 'n_0305', 'manual'],
  ['n_0311', 'n_0308', 'manual'], ['n_0315', 'n_0301', 'manual'],
  ['n_0401', 'n_0407', 'manual'], ['n_0401', 'n_0410', 'manual'], ['n_0404', 'n_0407', 'manual'], ['n_0413', 'n_0401', 'manual'],
  ['n_0401', 'n_0201', 'manual'], ['n_0401', 'n_0301', 'manual'], ['n_0401', 'n_0110', 'suggested'], ['n_0025', 'n_0401', 'suggested'],
  ['n_0413', 'n_0315', 'suggested'],
];
const BODY = {
  n_0042: `<p>결제 대행사가 보낸 웹훅에 우리 서버가 실패로 응답하면, 같은 이벤트를 다시 받는다. 재시도는 <b>3번까지</b> 간격을 늘려 가며 한다.</p>
    <ul><li>1차: 1분 뒤</li><li>2차: 10분 뒤</li><li>3차: 1시간 뒤</li></ul>
    <p>3번 모두 실패하면 <a class="wikilink" data-go="n_0077">[[결제 실패 알림]]</a>으로 넘긴다. 시험할 때는 <a class="wikilink" data-go="n_0063">[[토스 결제 테스트 키]]</a>로 먼저 확인한다.</p>`,
};
const LESSONS = [
  { id: 'L-0007', status: 'active', when: '결제 코드를 수정할 때', what: '테스트 키로 먼저 확인한 뒤 실제 키를 쓴다', why: '실제 키로 바로 테스트해 결제가 나간 적이 있음', kept: 3, re: 0, last: '11/28', tests: ['T-0003', 'T-0008'] },
  { id: 'L-0009', status: 'active', when: '커밋 메시지를 쓸 때', what: '한국어로 쓰고 feat·bug·misc 같은 접두사를 붙인다', why: '영어로 써서 다시 고친 적이 두 번 있음', kept: 7, re: 0, last: '11/30', tests: ['T-0005'] },
  { id: 'L-0010', status: 'active', when: '교수님께 메일을 쓸 때', what: '회사식으로 쓰고 "김민상 올림"으로 끝낸다', why: '서명이 빠진 초안을 고친 적이 있음', kept: 2, re: 1, last: '11/27', tests: ['T-0006'] },
  { id: 'L-0012', status: 'pending', src: 'observed', when: '결제 설정 값을 답할 때', what: '노트 수정일과 최근 대화를 함께 확인한다', why: '바뀌기 전 값(3번)으로 답한 적이 있음', kept: 0, re: 0, last: '-', tests: ['T-0014'] },
  { id: 'L-0003', status: 'archived', when: '그래프를 그릴 때', what: 'graphview 패키지를 쓴다', why: '설계가 CustomPainter로 바뀌어 보관', kept: 0, re: 0, last: '11/05', tests: [] },
];
const STATUS_LABEL = { active: '적용', pending: '승인 대기', archived: '보관' };

// ---------- 상태 ----------
const S = {
  screen: 'home', theme: 'dark', themePref: 'dark', view: 'graph', node: 'n_0042',
  chat: 'answered', connect: 'pending', lesson: 'L-0007', detailOpen: false, palIndex: 0,
  scope: 'all', depth: 1, raw: null, openTopics: null, structClosed: new Set(), pair: null, focusTopic: null, hoverTopic: null,
};
const byId = Object.fromEntries(NOTES.map((n) => [n.id, n]));
const topicName = (id) => TOPICS.find((t) => t.id === id)?.name ?? id;
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function readHash() {
  const p = new URLSearchParams(location.hash.slice(1));
  if (p.get('screen')) S.screen = p.get('screen');
  if (p.get('theme')) S.themePref = p.get('theme');
  if (p.get('view')) S.view = p.get('view');
  if (p.get('node')) S.node = p.get('node');
  if (p.get('chat')) S.chat = p.get('chat');
  if (p.get('connect')) S.connect = p.get('connect');
  if (p.get('lesson')) S.lesson = p.get('lesson');
  if (p.get('detail') === '1') S.detailOpen = true;
  if (p.get('scope')) S.scope = p.get('scope');
  if (p.get('depth')) S.depth = Number(p.get('depth'));
  if (p.get('raw')) S.raw = p.get('raw');
  if (p.get('pair')) S.pair = p.get('pair');
  if (p.get('focus')) S.focusTopic = p.get('focus');
  if (p.get('closed')) S.structClosed = new Set(p.get('closed').split(','));
  S.openTopics = new Set(p.get('open') ? p.get('open').split(',') : [byId[S.node].topic]);
  return p.get('cmdk') === '1' ? (p.get('q') ?? '웹훅') : null;
}
function applyTheme() {
  const sys = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  S.theme = S.themePref === 'system' ? sys : S.themePref;
  document.documentElement.dataset.theme = S.theme;
}

// ---------- 사이드바 ----------
function renderSidebar() {
  const nav = [
    ['home', 'graph', '홈'], ['notes', 'note', '노트', `<span class="count">${NOTES.length}</span>`],
    ['chat', 'chat', 'AI 질문'], ['lessons', 'lesson', '배운 것', '<span class="pill">1</span>'],
    ['todos', 'todo', '할 일', '<span class="count">4</span>'], ['import', 'import', '가져오기'],
    ['connect', 'plug', '연동', S.connect === 'pending' ? '<span class="dot" title="Codex 훅 승인 필요"></span>' : ''],
    ['settings', 'settings', '설정'],
  ];
  const counts = Object.fromEntries(TOPICS.map((t) => [t.id, NOTES.filter((n) => n.topic === t.id).length]));
  document.getElementById('sidebar').innerHTML = `
    <div class="traffic" aria-hidden="true"><span></span><span></span><span></span></div>
    <div class="brand"><span class="logo">${icon('brain', 14)}</span>세컨드 브레인 <span class="tentative">가칭</span></div>
    <button class="search-btn" data-action="cmdk">${icon('search', 14)} 찾기·명령 <span class="kbd">⌘K</span></button>
    <nav class="nav">
      ${nav.map(([id, ic, label, extra = '']) => `
        <button class="nav-item" data-nav="${id}" ${S.screen === id ? 'aria-current="page"' : ''}>
          ${icon(ic, 15)} ${label} ${extra}
        </button>`).join('')}
    </nav>
    <div class="side-section"><span>주제 · 파일</span><button class="side-act" title="지식 폴더를 Finder에서 열기">${icon('folder', 12)} Finder</button></div>
    <div class="topics">
      ${TOPICS.map((t) => {
        const isOpen = S.openTopics.has(t.id);
        const files = NOTES.filter((n) => n.topic === t.id);
        return `<div class="topic ${isOpen ? 'open' : ''}" data-topic="${t.id}" title="wiki/${esc(t.name)}/" role="button" aria-expanded="${isOpen}">
            <span class="chev">${icon(isOpen ? 'chevdown' : 'chevright', 12)}</span>${icon('folder', 13)}${t.name}<span class="count">${counts[t.id]}</span></div>
          ${isOpen ? `<div class="files">${files.map((n) => `<div class="file ${n.id === S.node && !S.raw ? 'sel' : ''}" data-file="${n.id}" title="wiki/${esc(t.name)}/${esc(n.t)}.md">
            ${icon('file', 12)}<span class="fname">${esc(n.t)}<span class="ext">.md</span></span>${n.lint ? `<span class="fdot ${n.lint[0]}" title="${esc(n.lint[1])}"></span>` : ''}</div>`).join('')}</div>` : ''}`;
      }).join('')}
      <div class="topic raw-topic ${S.openTopics.has('raw') ? 'open' : ''}" data-topic="raw" title="raw/ — 정리 전 원본" role="button" aria-expanded="${S.openTopics.has('raw')}">
        <span class="chev">${icon(S.openTopics.has('raw') ? 'chevdown' : 'chevright', 12)}</span>${icon('folder', 13)}원본 (raw)<span class="count">${RAW.length}</span></div>
      ${S.openTopics.has('raw') ? `<div class="files">${RAW.map((r) => `<div class="file ${S.raw === r.id ? 'sel' : ''}" data-raw-file="${r.id}" title="${esc(r.path)}">${icon('file', 12)}<span class="fname">${esc(r.path.split('/').slice(1).join('/'))}</span></div>`).join('')}</div>` : ''}
    </div>
    <div class="side-bottom">
      <div class="status-line"><span class="led ok"></span>Claude Code 연결됨</div>
      <div class="status-line"><span class="led ${S.connect === 'pending' ? 'warn' : 'ok'}"></span>Codex ${S.connect === 'pending' ? '훅 승인 필요' : '연결됨'}</div>
      <div class="vault-line">${icon('folder', 12)} ~/SecondBrain · 노트 ${NOTES.length}개</div>
      <div class="theme-label">테마 (시안 확인용)</div>
      <div class="theme-switch" role="group" aria-label="테마">
        ${[['system', '시스템'], ['light', '라이트'], ['dark', '다크']].map(([v, l]) => `<button data-theme-pref="${v}" aria-pressed="${S.themePref === v}">${l}</button>`).join('')}
      </div>
    </div>`;
}

// ---------- 그래프 배치 (시안용 force 배치, 노드가 적어 모든 쌍을 계산) ----------
function mulberry32(a) {
  return () => { a |= 0; a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
let LAYOUT = null;
function layoutGraph() {
  if (LAYOUT) return LAYOUT;
  const rand = mulberry32(7);
  const W = 1000, H = 760;
  const centers = {};
  TOPICS.forEach((t, i) => {
    const a = (i / TOPICS.length) * Math.PI * 2 - Math.PI / 2;
    centers[t.id] = { x: W / 2 + Math.cos(a) * 270, y: H / 2 + Math.sin(a) * 220 };
  });
  const nodes = NOTES.map((n) => ({ id: n.id, topic: n.topic, x: centers[n.topic].x + (rand() - 0.5) * 90, y: centers[n.topic].y + (rand() - 0.5) * 90, vx: 0, vy: 0 }));
  const idx = Object.fromEntries(nodes.map((n, i) => [n.id, i]));
  const deg = Object.fromEntries(nodes.map((n) => [n.id, 0]));
  LINKS.forEach(([a, b]) => { deg[a]++; deg[b]++; });
  for (let it = 0; it < 300; it++) {
    const alpha = 1 - it / 300;
    for (let i = 0; i < nodes.length; i++) {
      for (let j = i + 1; j < nodes.length; j++) {
        const A = nodes[i], B = nodes[j];
        let dx = A.x - B.x, dy = A.y - B.y; const d2 = Math.max(dx * dx + dy * dy, 30); const d = Math.sqrt(d2);
        const f = 2600 / d2; dx /= d; dy /= d;
        A.vx += dx * f; A.vy += dy * f; B.vx -= dx * f; B.vy -= dy * f;
      }
    }
    LINKS.forEach(([a, b, k]) => {
      const A = nodes[idx[a]], B = nodes[idx[b]];
      const dx = B.x - A.x, dy = B.y - A.y; const d = Math.max(Math.hypot(dx, dy), 1);
      const f = (d - (k === 'suggested' ? 120 : 78)) * (k === 'suggested' ? 0.012 : 0.04);
      A.vx += (dx / d) * f; A.vy += (dy / d) * f; B.vx -= (dx / d) * f; B.vy -= (dy / d) * f;
    });
    nodes.forEach((n) => {
      const c = centers[n.topic];
      n.vx += (c.x - n.x) * 0.012 + (W / 2 - n.x) * 0.002; n.vy += (c.y - n.y) * 0.012 + (H / 2 - n.y) * 0.002;
      n.vx *= 0.82; n.vy *= 0.82; n.x += n.vx * alpha; n.y += n.vy * alpha;
    });
  }
  const xs = nodes.map((n) => n.x), ys = nodes.map((n) => n.y);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
  const pad = 70;
  nodes.forEach((n) => { n.x = pad + ((n.x - minX) / (maxX - minX)) * (W - pad * 2); n.y = pad + ((n.y - minY) / (maxY - minY)) * (H - pad * 2); n.r = Math.min(4.5 + deg[n.id] * 1.2, 11); });
  const topicPos = TOPICS.map((t) => {
    const ns = nodes.filter((n) => n.topic === t.id);
    return { name: t.name, x: ns.reduce((s, n) => s + n.x, 0) / ns.length, y: Math.min(...ns.map((n) => n.y)) - 26 };
  });
  LAYOUT = { W, H, nodes, idx, topicPos };
  return LAYOUT;
}
function neighbors(id) {
  const s = new Set();
  LINKS.forEach(([a, b]) => { if (a === id) s.add(b); if (b === id) s.add(a); });
  return s;
}
function localLayout() {
  const W = 1000, H = 760, cx = W / 2, cy = H / 2 + 10;
  const n1 = [...neighbors(S.node)];
  const n2 = [], parentOf = {};
  if (S.depth === 2) n1.forEach((p) => neighbors(p).forEach((q) => { if (q !== S.node && !n1.includes(q) && !n2.includes(q)) { n2.push(q); parentOf[q] = p; } }));
  const nodes = [{ id: S.node, x: cx, y: cy, r: 12 }];
  const ang = {};
  n1.forEach((id, i) => { const a = -Math.PI / 2 + (i / n1.length) * Math.PI * 2; ang[id] = a; nodes.push({ id, x: cx + Math.cos(a) * 210, y: cy + Math.sin(a) * 190, r: 8 }); });
  const kids = {};
  n2.forEach((q) => (kids[parentOf[q]] ??= []).push(q));
  const sector = (Math.PI * 2) / Math.max(n1.length, 1);
  Object.entries(kids).forEach(([p, qs]) => qs.forEach((q, j) => {
    const a = ang[p] + (qs.length === 1 ? 0 : (j / (qs.length - 1) - 0.5) * sector * 0.8);
    nodes.push({ id: q, x: cx + Math.cos(a) * 360, y: cy + Math.sin(a) * 310, r: 5.5 });
  }));
  const ids = new Set(nodes.map((n) => n.id));
  return { W, H, nodes, idx: Object.fromEntries(nodes.map((n, i) => [n.id, i])), links: LINKS.filter(([a, b]) => ids.has(a) && ids.has(b)), topicPos: [], labelSide: true };
}
function drawGraph(L, showTopics) {
  const nb = neighbors(S.node);
  const links = L.links ?? LINKS;
  const at = (id) => L.nodes[L.idx[id]];
  const edges = links.map(([a, b, k]) => {
    const A = at(a), B = at(b);
    const hl = a === S.node || b === S.node;
    return `<line class="edge ${k === 'suggested' ? 'suggested' : ''} ${hl && k !== 'suggested' ? 'hl' : ''}" x1="${A.x}" y1="${A.y}" x2="${B.x}" y2="${B.y}"/>`;
  }).join('');
  const nodes = L.nodes.map((n) => {
    const cls = n.id === S.node ? 'sel' : nb.has(n.id) ? 'nb' : '';
    const halo = n.id === S.node ? n.r * 3.2 : nb.has(n.id) ? n.r * 2.4 : n.r * 2;
    return `<g class="node ${cls}" data-node="${n.id}" tabindex="0" role="button" aria-label="${esc(byId[n.id].t)}">
      <circle class="halo" cx="${n.x}" cy="${n.y}" r="${halo}" filter="url(#blur)"/>
      <circle class="core" cx="${n.x}" cy="${n.y}" r="${n.r}"/></g>`;
  }).join('');
  const labels = L.nodes.map((n) => {
    const hl = n.id === S.node || nb.has(n.id);
    const left = L.labelSide ? n.x < L.W / 2 - 20 : n.x > L.W - 170;
    return `<text class="label ${hl ? 'hl' : ''}" x="${left ? n.x - n.r - 6 : n.x + n.r + 6}" y="${n.y + 4}" text-anchor="${left ? 'end' : 'start'}">${esc(byId[n.id].t)}</text>`;
  }).join('');
  const topics = showTopics ? L.topicPos.map((t) => `<text class="topic-label" x="${t.x}" y="${t.y}" text-anchor="middle">${esc(t.name)}</text>`).join('') : '';
  return `<svg viewBox="0 0 ${L.W} ${L.H}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="뇌 그래프">
    <defs><filter id="blur" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="6"/></filter></defs>
    ${topics}<g>${edges}</g><g>${nodes}</g><g>${labels}</g></svg>`;
}

// ---------- 가운데 ----------
function toolbar(title, inner = '') {
  return `<div class="toolbar"><h1>${title}</h1>${inner}<span class="spacer"></span>
    <span class="mock-badge">시안 · 모의 데이터</span>
    <button class="icon-btn only-narrow" data-action="toggle-detail" title="오른쪽 패널">${icon('panel', 15)}</button></div>`;
}
function renderHome() {
  const views = [['graph', 'graph', '그래프'], ['list', 'listtree', '목록'], ['timeline', 'clock', '타임라인'], ['board', 'board', '정리 보드']];
  const seg = `<div class="seg" role="group" aria-label="보기">${views.map(([v, ic, l]) => `<button data-view="${v}" aria-pressed="${S.view === v}">${icon(ic, 13)} ${l}</button>`).join('')}</div>`;
  const filters = `<button class="chip on">정리된 노트</button><button class="chip">원본 포함</button>`;
  if (S.view === 'timeline') return toolbar('홈', seg) + renderTimeline();
  if (S.view === 'board') return toolbar('홈', seg) + renderBoard();
  if (S.view === 'list') return toolbar('홈', seg + filters) + renderStructure();
  const local = S.scope === 'local';
  return toolbar('홈', seg + filters) + `<div class="graph-wrap">
      <div class="graph-hint">${local ? `“${esc(byId[S.node].t)}” 주변 ${S.depth}단계 · 노드를 누르면 그 노트가 가운데로 와요` : `노트 ${NOTES.length} · 연결 ${LINKS.length} · 노드를 누르면 오른쪽에 노트가 열려요`}</div>
      <div class="graph-scope">
        <div class="seg dark" role="group" aria-label="범위"><button data-scope="all" aria-pressed="${!local}">전체</button><button data-scope="local" aria-pressed="${local}">${icon('focus', 12)} 이 노트 주변</button></div>
        ${local ? `<div class="seg dark" role="group" aria-label="단계"><button data-depth="1" aria-pressed="${S.depth === 1}">1단계</button><button data-depth="2" aria-pressed="${S.depth === 2}">2단계</button></div>` : ''}
      </div>
      ${local ? drawGraph(localLayout(), false) : drawGraph(layoutGraph(), true)}
      <div class="graph-legend"><span><i class="lg-node"></i>선택한 노트</span><span><i class="lg-line"></i>직접 연결 [[ ]]</span><span><i class="lg-dash"></i>추천 연결</span></div>
      <div class="graph-zoom"><button class="icon-btn" title="확대">${icon('plus', 14)}</button><button class="icon-btn" title="축소">${icon('minus', 14)}</button></div>
    </div>`;
}

// ---------- 타임라인 ----------
const SRC = { claude: ['Claude Code', 'terminal'], codex: ['Codex', 'terminal'], app: ['앱 안 질문', 'chat'], import: ['가져오기', 'import'], lint: ['점검', 'alert'], user: ['직접', 'note'] };
const EVENTS = [
  { day: '오늘 · 11/21 (금)', items: [
    { t: '14:32', src: 'claude', kind: 'new', text: '세션 대화에서 새 노트를 정리했어요', notes: ['n_0077'], sub: 'raw/sessions/2026-11-21-claude.md → wiki/결제' },
    { t: '14:30', src: 'claude', kind: 'use', text: 'brain find "결제 웹훅"으로 노트를 찾아 읽었어요', notes: ['n_0042'], sub: '우리 서버 호출 0회' },
    { t: '11:05', src: 'app', kind: 'fix', text: '교정을 반영했어요: 재시도 3번 → 5번', notes: ['n_0042'], lesson: 'L-0012', sub: '회귀 시험 3개 통과 · 규칙 L-0012 승인 대기' },
    { t: '10:12', src: 'user', kind: 'link', text: '추천 연결을 확정했어요', notes: ['n_0042', 'n_0012'] },
  ] },
  { day: '어제 · 11/20 (목)', items: [
    { t: '21:40', src: 'codex', kind: 'new', text: '세션 대화에서 새 노트를 정리했어요', notes: ['n_0110'], sub: 'raw/sessions/2026-11-20-codex.md → wiki/Flutter' },
    { t: '16:02', src: 'import', kind: 'import', text: 'ChatGPT 대화 12개를 가져왔어요', sub: 'raw/imports · 정리 대기 4 · 비밀값 2개 가림' },
    { t: '09:15', src: 'app', kind: 'rule', text: '교정이 규칙이 됐어요', lesson: 'L-0007', sub: '회귀 시험 2개 통과 후 적용' },
  ] },
  { day: '11/18 (화)', items: [
    { t: '13:20', src: 'lint', kind: 'lint', text: '점검에서 문제 2개를 찾았어요', notes: ['n_0051', 'n_0070'], sub: '중복 후보 1 · 죽은 링크 1' },
    { t: '10:00', src: 'import', kind: 'new', text: '가져온 문서에서 새 노트를 만들었어요', notes: ['n_0051'] },
  ] },
];
const WEEK = [['11/15', 2], ['11/16', 0], ['11/17', 3], ['11/18', 5], ['11/19', 1], ['11/20', 7], ['11/21', 6]];
function renderTimeline() {
  const max = Math.max(...WEEK.map((w) => w[1]));
  const evRow = (ev) => {
    const [srcName, ic] = SRC[ev.src];
    const chips = (ev.notes ?? []).map((id) => `<span class="note-chip ${id === S.node ? 'on' : ''}" data-node="${id}">${esc(byId[id].t)}</span>`).join('')
      + (ev.lesson ? `<span class="note-chip lesson" data-go-lesson="${ev.lesson}">${ev.lesson}</span>` : '');
    return `<div class="ev"><span class="ev-time mono">${ev.t}</span><span class="ev-dot ${ev.kind}">${icon(ic, 13)}</span>
      <div class="ev-main"><div class="ev-text">${esc(ev.text)} <span class="src-badge">${srcName}</span></div>
      ${chips ? `<div class="ev-chips">${chips}</div>` : ''}${ev.sub ? `<div class="ev-sub">${esc(ev.sub)}</div>` : ''}</div></div>`;
  };
  return `<div class="tl">
    <div class="tl-summary">
      <div class="tl-stats"><div><b>+9</b><span>새 노트</span></div><div><b>14</b><span>고친 노트</span></div><div><b>2</b><span>교정</span></div><div><b>+1</b><span>규칙</span></div></div>
      <div class="week-bars" aria-label="최근 7일 활동">${WEEK.map(([d, n], i) => `<div class="wb ${i === WEEK.length - 1 ? 'today' : ''}" title="${d} · ${n}건"><i style="height:${Math.max(4, (n / max) * 44)}px"></i><span>${d.slice(3)}</span></div>`).join('')}</div>
    </div>
    <div class="tl-filter">${['전체', '새 노트', '교정·규칙', 'AI 사용', '점검'].map((f, i) => `<button class="chip ${i === 0 ? 'on' : ''}">${f}</button>`).join('')}<span class="spacer"></span><span class="faint" style="font-size:11.5px">지식 폴더 _log/ 기록으로 만든 화면이에요</span></div>
    ${EVENTS.map((g) => `<div class="day"><div class="day-title">${g.day}</div>${g.items.map(evRow).join('')}</div>`).join('')}
  </div>`;
}

// ---------- 정리 보드 ----------
const RAW = [
  { id: 'r1', t: '결제 연동 질문 (ChatGPT)', src: 'import', when: '11/20', path: 'raw/imports/2026-11-20-chatgpt-결제.md', size: '대화 18턴', masked: 1,
    preview: 'user: 웹훅 재시도는 몇 번이 적당해?\nassistant: 보통 3~5번 간격을 늘려…\nuser: 테스트 키는 [가림] 이거 써' },
  { id: 'r2', t: '그래프 성능 이야기 (Codex)', src: 'codex', when: '11/20', path: 'raw/sessions/2026-11-20-codex.md', size: '대화 42턴 · 도구 출력 줄임', masked: 0,
    preview: 'user: 노드 1만 개면 그래프가 버벅여\nassistant: 모든 쌍을 계산하면 n²이라…\n[도구 출력 3개 줄임]' },
  { id: 'r3', t: '1주차 점검 회의록', src: 'user', when: '11/12', path: 'raw/meetings/2026-11-12-1주차.md', size: '텍스트 3.2KB', masked: 0,
    preview: '- Xcode 설치 완료, flutter doctor 통과\n- FTS5 contentless 확인 필요\n- 다음: 화면 시안 검토' },
];
const BOARD = [
  { title: '원본', desc: '정리 전 · 내용은 고치지 않아요', items: RAW.map((r) => ({ raw: r.id })) },
  { title: '정리 대기', desc: 'AI 초안 · 확인하면 정리됨으로', items: [{ draft: '환불 부분 취소 정리', from: 'r1' }, { draft: '그래프 Barnes–Hut 적용 메모', from: 'r2' }] },
  { title: '정리됨', desc: '최근 7일', items: [{ note: 'n_0077' }, { note: 'n_0110' }, { note: 'n_0042', badge: '고침' }] },
  { title: '점검 필요', desc: 'brain lint 결과', items: [{ note: 'n_0051', issue: '중복 후보 · n_0042', act: '합치기 보기' }, { note: 'n_0070', issue: '죽은 링크 1', act: '고치기' }, { note: 'n_0119', issue: '고아 노트', act: '연결 추천' }] },
];
function boardCard(it) {
  if (it.raw) {
    const r = RAW.find((x) => x.id === it.raw);
    return `<div class="bcard ${S.raw === r.id ? 'sel' : ''}" data-raw="${r.id}" tabindex="0"><div class="bt">${esc(r.t)}</div>
      <div class="bm"><span class="src-badge">${SRC[r.src][0]}</span><span>${r.when}</span>${r.masked ? `<span class="masked">${icon('shield', 11)} 비밀값 ${r.masked} 가림</span>` : ''}</div></div>`;
  }
  if (it.draft) {
    const r = RAW.find((x) => x.id === it.from);
    return `<div class="bcard draft"><div class="bt">${esc(it.draft)}</div><div class="bs">원본: ${esc(r.t)}</div>
      <div class="bm"><span class="src-badge">brain-ingest 초안</span></div><div class="ba"><button class="mini-btn primary">확인</button><button class="mini-btn">고치기</button></div></div>`;
  }
  const n = byId[it.note];
  return `<div class="bcard ${!S.raw && S.node === n.id ? 'sel' : ''}" data-node="${n.id}" tabindex="0"><div class="bt">${esc(n.t)}${it.badge ? ` <span class="lint info">${it.badge}</span>` : ''}</div>
    ${it.issue ? `<div class="issue">${icon('alert', 11)} ${esc(it.issue)}</div>` : `<div class="bs">${esc(n.s)}</div>`}
    <div class="bm"><span class="mono">${n.id}</span><span>wiki/${esc(topicName(n.topic))}</span></div>
    ${it.act ? `<div class="ba"><button class="mini-btn">${it.act}</button></div>` : ''}</div>`;
}
function renderBoard() {
  return `<div class="board-wrap">
    <div class="board-hint">${icon('terminal', 13)} 연동한 AI에게 "원본 정리해 줘"라고 하면 <span class="code-inline">brain-ingest</span> 스킬이 초안을 만들어 정리 대기에 올려요</div>
    <div class="board">${BOARD.map((col) => `<section class="col"><header><b>${col.title}</b><span class="n">${col.items.length}</span><span class="faint">${col.desc}</span></header>${col.items.map(boardCard).join('')}</section>`).join('')}</div>
  </div>`;
}

function renderNotes() {
  return toolbar('노트', `<button class="chip on">정리된 노트</button><button class="chip">원본 포함</button><span class="faint" style="font-size:11.5px;margin-left:6px">노트 ${NOTES.length}개 · 표로 보기</span>`) + `<div class="list">
      <div class="list-head"><span>id</span><span>제목 — 요약</span><span>폴더</span><span>수정</span></div>
      ${NOTES.map((n) => `<div class="list-row ${n.id === S.node ? 'sel' : ''}" data-node="${n.id}">
        <span class="mono faint">${n.id}</span>
        <span class="sum"><span class="ttl">${esc(n.t)}</span>${n.lint ? `<span class="lint ${n.lint[0]}">${n.lint[0] === 'warn' ? icon('alert', 10) : ''}${esc(n.lint[1])}</span>` : ''}<span class="faint"> — ${esc(n.s)}</span></span>
        <span class="faint">wiki/${esc(topicName(n.topic))}</span><span class="faint">${n.up}</span></div>`).join('')}
    </div>`;
}

// ---------- 구조 목록: 그래프를 주제 → 노트 → 연결 순서로 펼친 목록 ----------
const STRUCT_ORDER = ['search', 'ai', 'project', 'server', 'pay', 'flutter'];
// 주제 쌍마다 서로 다른 주제의 노트를 잇는 연결을 모은다
function topicPairs() {
  const m = {};
  LINKS.forEach(([a, b, k]) => {
    const ta = byId[a].topic, tb = byId[b].topic;
    if (ta === tb) return;
    const [x, y] = [ta, tb].sort((u, v) => STRUCT_ORDER.indexOf(u) - STRUCT_ORDER.indexOf(v));
    const key = `${x}|${y}`;
    (m[key] ??= { key, a: x, b: y, links: [] }).links.push([a, b, k]);
  });
  return Object.values(m).sort((u, v) => v.links.length - u.links.length);
}
const degOf = (id) => LINKS.filter(([a, b]) => a === id || b === id).length;
function topicTree(tid) {
  const ns = NOTES.filter((n) => n.topic === tid).map((n) => n.id);
  const inT = new Set(ns);
  const adj = (id) => LINKS.filter(([a, b, k]) => k === 'manual' && (a === id || b === id)).map(([a, b]) => (a === id ? b : a)).filter((x) => inT.has(x));
  const order = [...ns].sort((a, b) => degOf(b) - degOf(a));
  const seen = new Set(), roots = [], treeEdges = new Set();
  for (const r of order) {
    if (seen.has(r)) continue;
    seen.add(r);
    const root = { id: r, kids: [] }; roots.push(root);
    const q = [root];
    while (q.length) {
      const cur = q.shift();
      for (const k of adj(cur.id).sort((a, b) => degOf(b) - degOf(a))) {
        if (seen.has(k)) continue;
        seen.add(k); treeEdges.add([cur.id, k].sort().join('|'));
        const ch = { id: k, kids: [] }; cur.kids.push(ch); q.push(ch);
      }
    }
  }
  const rows = [];
  const walk = (list, anc) => list.forEach((n, i) => { const last = i === list.length - 1; rows.push({ id: n.id, anc, last, depth: anc.length }); walk(n.kids, [...anc, last]); });
  walk(roots, []);
  return { rows, treeEdges };
}
function renderStructure() {
  const nb = neighbors(S.node);
  const pairs = topicPairs();
  const pair = S.pair ? pairs.find((x) => x.key === S.pair) : null;
  const focusPairs = pair ? [pair] : S.focusTopic ? pairs.filter((x) => x.a === S.focusTopic || x.b === S.focusTopic) : [];
  const pairNodes = new Set(focusPairs.flatMap((x) => x.links.flatMap(([a, b]) => [a, b])));
  const focusTopics = new Set(focusPairs.flatMap((x) => [x.a, x.b]));
  const sections = STRUCT_ORDER.map((tid) => {
    const { rows, treeEdges } = topicTree(tid);
    const closed = S.structClosed.has(tid);
    const active = focusPairs.length ? focusTopics.has(tid) : byId[S.node].topic === tid;
    const rel = pairs.filter((x) => x.a === tid || x.b === tid).map((x) => `${esc(topicName(x.a === tid ? x.b : x.a))} ${x.links.length}`).join(' · ');
    const hub = rows[0];
    const head = `<div class="s-topic ${active ? 'active' : ''} ${S.focusTopic === tid ? 'focus' : ''}" style="grid-row: 1 / span ${closed ? 1 : rows.length}">
        <button class="s-chev" data-struct-topic="${tid}" aria-expanded="${!closed}" title="${closed ? '펼치기' : '접기'}">${icon(closed ? 'chevright' : 'chevdown', 12)}</button>
        <div class="s-tname" data-focus-topic="${tid}" role="button" title="누르면 이 주제와 다른 주제의 연결을 보여 줘요"><div class="s-name">${esc(topicName(tid))}</div><div class="s-meta">노트 ${rows.length} · 허브 ${esc(byId[hub.id].t)}</div>${rel ? `<div class="s-rel">↔ ${rel}</div>` : ''}</div></div>
      <div class="s-brace ${active ? 'active' : ''}" style="grid-row: 1 / span ${closed ? 1 : rows.length}">
        <svg viewBox="0 0 20 100" preserveAspectRatio="none" aria-hidden="true"><path d="M17 1 C 9 1, 10 8, 10 22 L 10 40 C 10 47, 7 50, 2 50 C 7 50, 10 53, 10 60 L 10 78 C 10 92, 9 99, 17 99" vector-effect="non-scaling-stroke"/></svg></div>`;
    if (closed) return `<section class="s-sec closed">${head}<div class="s-row s-collapsed" style="grid-column: 4 / span 2">노트 ${rows.length}개 접힘</div></section>`;
    const body = rows.map((r) => {
      const glyph = r.anc.map((l) => (l ? '   ' : '│  ')).join('') + (r.depth ? (r.last ? '└─ ' : '├─ ') : '');
      const others = LINKS.filter(([a, b]) => a === r.id || b === r.id)
        .map(([a, b, k]) => ({ o: a === r.id ? b : a, k }))
        .filter(({ o }) => !treeEdges.has([r.id, o].sort().join('|')));
      const cls = focusPairs.length ? (pairNodes.has(r.id) ? 'pairhl' : '') : r.id === S.node ? 'sel' : nb.has(r.id) ? 'nb' : '';
      const shown = others.slice(0, 3);
      const chips = shown.map(({ o, k }) => {
        const same = byId[o].topic === tid;
        return `<span class="s-chip ${k === 'suggested' ? 'sugg' : ''} ${o === S.node ? 'on' : ''}" data-node="${o}" title="${k === 'suggested' ? '추천 연결' : '직접 연결'}">${icon('arrow', 11)}${esc(byId[o].t)}<span class="s-ct">${same ? '같은 주제' : esc(topicName(byId[o].topic))}</span></span>`;
      }).join('') + (others.length > 3 ? `<span class="s-chip more" data-node="${r.id}" title="이 노트를 골라 연결 모두 보기">+${others.length - 3}</span>` : '');
      const d = degOf(r.id);
      return `<div class="s-row ${cls}" data-node="${r.id}" data-row="${r.id}"><span class="s-tree mono">${glyph}</span><span class="s-dot"></span><span class="s-title">${esc(byId[r.id].t)}</span>${r.depth === 0 && d >= 4 ? '<span class="s-hub">허브</span>' : ''}<span class="s-deg" title="연결 수">${d}</span></div>
        <div class="s-links ${cls}">${chips || '<span class="s-none">—</span>'}</div>`;
    }).join('');
    return `<section class="s-sec">${head}${body}</section>`;
  }).join('');
  return `<div class="struct" id="struct">
    <div class="s-hint"><span>그래프를 <b>주제 → 노트 → 연결</b> 순서로 펼쳤어요 · 같은 주제 안은 들여쓰기, 나머지는 오른쪽 칩</span>
      <span class="s-legend"><span><i class="lg-arc"></i>선택한 노트의 연결</span><span><i class="lg-dash"></i>추천 연결</span></span></div>
    <div class="s-cols"><span>주제</span><span></span><span>노트 (연결 많은 순)</span><span>다른 주제·그 밖의 연결</span></div>
    <div class="s-body" id="s-body">${sections}<svg class="s-arcs" id="s-arcs" aria-hidden="true"></svg></div>
  </div>`;
}
// 선택한 노트에서 연결된 노트 줄까지 오른쪽 여백에 호(arc)를 그린다
function drawArcs() {
  const body = document.getElementById('s-body'); const svg = document.getElementById('s-arcs');
  if (!body || !svg) return;
  const W = body.clientWidth, H = body.scrollHeight;
  svg.setAttribute('width', W); svg.setAttribute('height', H); svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
  const base = body.getBoundingClientRect();
  const yOf = (el) => el.getBoundingClientRect().top - base.top + body.scrollTop + el.offsetHeight / 2;
  const rowOf = (id) => body.querySelector(`.s-row[data-row="${id}"]`);
  const secOf = (tid) => body.querySelector(`.s-tname[data-focus-topic="${tid}"]`);
  const xL = 20 + 44 - 4, xR = W - 20 - 50;
  const parts = [];
  const pairs = topicPairs();
  const pair = S.pair ? pairs.find((x) => x.key === S.pair) : null;
  const focusPairs = pair ? [pair] : S.focusTopic ? pairs.filter((x) => x.a === S.focusTopic || x.b === S.focusTopic) : [];
  // 마우스를 올린 주제: 아직 안 누른 쌍만 흐리게 미리 보여 준다
  const previewPairs = S.hoverTopic && S.hoverTopic !== S.focusTopic
    ? pairs.filter((x) => (x.a === S.hoverTopic || x.b === S.hoverTopic) && !focusPairs.includes(x)) : [];
  const drawn = [...previewPairs.map((x) => [x, true]), ...focusPairs.map((x) => [x, false])];
  if (drawn.length) {
    const placed = [];
    drawn.forEach(([p, preview], pi) => {
      const ea = secOf(p.a), eb = secOf(p.b); if (!ea || !eb) return;
      const y1 = yOf(ea), y2 = yOf(eb), n = p.links.length;
      // 멀리 떨어진 주제일수록 바깥으로 크게 휘게 해서 호끼리 덜 겹치게 한다
      const span = Math.abs(STRUCT_ORDER.indexOf(p.b) - STRUCT_ORDER.indexOf(p.a));
      const b = Math.min(38, 8 + span * 6 + (pi % 2) * 3);
      const d = `M ${xL} ${y1} C ${xL - b} ${y1}, ${xL - b} ${y2}, ${xL} ${y2}`;
      const on = !preview, dim = false;
      const sugg = p.links.every((l) => l[2] === 'suggested');
      parts.push(`<path class="tarc ${sugg ? 'sugg' : ''} ${on ? 'on' : ''} ${preview ? 'preview' : ''}" d="${d}" style="stroke-width:${1 + n * 1.5}px"/>${preview ? '' : `<path class="hit" data-pair="${p.key}" d="${d}"/>`}`);
      const mx = xL - b * 0.75; let my = (y1 + y2) / 2;
      while (placed.some(([px, py]) => Math.abs(px - mx) < 18 && Math.abs(py - my) < 18)) my += 19;
      placed.push([mx, my]);
      parts.push(`<g class="tcount ${on ? 'on' : ''} ${preview ? 'preview' : ''}" ${preview ? '' : `data-pair="${p.key}"`}><circle cx="${mx}" cy="${my}" r="8.5"/><text x="${mx}" y="${my + 3.5}" text-anchor="middle">${n}</text></g>`);
    });
  }
  const links = [];
  if (focusPairs.length) focusPairs.forEach((x) => x.links.forEach((l) => links.push({ l, cls: 'pair' })));
  else {
    LINKS.filter(([a, b]) => a === S.node || b === S.node).forEach((l) => links.push({ l, cls: 'sel' }));
  }
  links.forEach(({ l: [a, b, k], cls }) => {
    const ra = rowOf(a), rb = rowOf(b); if (!ra || !rb) return;
    const y1 = yOf(ra), y2 = yOf(rb);
    const bulge = Math.min(40, 10 + Math.abs(y2 - y1) * 0.08);
    parts.push(`<path class="arc ${cls} ${k === 'suggested' ? 'sugg' : ''}" d="M ${xR} ${y1} C ${xR + bulge} ${y1}, ${xR + bulge} ${y2}, ${xR} ${y2}"/><circle class="arc-end ${cls}" cx="${xR}" cy="${y1}" r="2.5"/><circle class="arc-end ${cls}" cx="${xR}" cy="${y2}" r="2.5"/>`);
  });
  svg.innerHTML = parts.join('');
}
window.addEventListener('resize', () => requestAnimationFrame(drawArcs));
document.addEventListener('mouseover', (e) => {
  const k = e.target.closest?.('[data-focus-topic]')?.dataset.focusTopic ?? null;
  if (k !== S.hoverTopic) { S.hoverTopic = k; drawArcs(); }
});

function renderChat() {
  const answer = `<div class="msg-ai"><span class="avatar">${icon('brain', 14)}</span><div class="content">
      <div class="text"><b>3번</b>까지 간격을 늘려 재시도하도록 정해 두셨어요. 1분 → 10분 → 1시간 순서예요 <span class="cite" data-go="n_0042">n_0042</span>.
      재시도를 시험할 때는 실제 키 대신 테스트 키로 먼저 확인하라는 규칙도 있어요 <span class="cite" data-go-lesson="L-0007">L-0007</span>.</div>
      <div class="msg-meta"><span class="tag">근거 노트 2</span><span class="tag">적용한 규칙 1</span><span class="tag">검증 통과</span></div>
      ${S.chat === 'answered' ? `<div class="msg-actions"><button class="btn">${icon('thumbs', 13)} 맞아요</button><button class="btn" data-action="wrong">${icon('x', 13)} 틀렸어</button></div>` : ''}
      ${S.chat === 'correcting' ? `<div class="correct-card"><h3>무엇이 틀렸나요?</h3>
        <textarea id="fix-text" aria-label="고친 내용">지난주에 5번으로 바꿨어. 간격은 1분 · 5분 · 30분 · 2시간 · 6시간이야.</textarea>
        <div class="row"><button class="btn" data-action="cancel-wrong">취소</button><button class="btn primary" data-action="save-fix">교정 저장</button></div></div>` : ''}
      ${S.chat === 'verifying' || S.chat === 'corrected' ? correctionResult() : ''}
    </div></div>`;
  return toolbar('AI 질문', `<span class="faint" style="font-size:11.5px">앱 안 질문은 우리 게이트웨이를 거쳐요 · 찾은 노트 일부만 보내요</span>`) +
    `<div class="chat"><div class="chat-col">
      <div class="msg-user">결제 웹훅이 실패하면 몇 번 재시도하게 해 뒀지?</div>
      ${answer}
    </div></div>
    <div class="composer"><div class="composer-box"><input placeholder="내 지식에 대해 물어보기…" aria-label="질문"><button class="btn primary">${icon('send', 13)} 보내기</button></div>
      <div class="composer-note"><span>이번 달 13 / 50회 (무료)</span><span>답에는 근거 노트 id가 붙어요</span></div></div>`;
}
function correctionResult() {
  const done = S.chat === 'corrected';
  const st = (ok, t, sub) => `<div class="step"><span class="mk ${ok}">${ok === 'ok' ? icon('check', 11) : ok === 'wait' ? '…' : ''}</span><div class="d">${t}${sub ? `<span class="faint">${sub}</span>` : ''}</div></div>`;
  return `<div class="correct-card"><h3>교정을 저장했어요</h3>
    <div class="faint" style="font-size:11.5px">AI가 쓴 것 → 고친 것 (diff)</div>
    <div class="diff"><div class="del">- 3번까지 재시도 (1분 → 10분 → 1시간)</div><div class="add">+ 5번까지 재시도 (1분 → 5분 → 30분 → 2시간 → 6시간)</div></div>
    <div class="steps">
      ${st('ok', '교정 저장', 'diff와 질문·답을 함께 남김')}
      ${st(done ? 'ok' : 'wait', '검증 에이전트 판단', done ? '진짜 교정 · 노트 n_0042의 값이 옛날 값이었음' : '새 맥락의 보조 에이전트가 확인하는 중')}
      ${st(done ? 'ok' : 'todo', '관련 회귀 시험', done ? 'T-0003 · T-0008 · T-0014 모두 통과 (이전 사례를 깨지 않음)' : '')}
      ${st(done ? 'ok' : 'todo', '결과', done ? '노트 n_0042 고침 제안 + 실수 노트 L-0012 승인 대기' : '')}
    </div>
    ${done ? `<div class="row" style="justify-content:flex-start;margin-top:12px"><button class="btn primary" data-go="n_0042">노트 고침 보기</button><button class="btn" data-nav="lessons">L-0012 승인하러 가기</button></div>` : ''}
  </div>`;
}
function renderLessons() {
  const tabs = `<div class="tabs" role="tablist"><button class="tab" role="tab" aria-selected="true">실수 노트<span class="n">${LESSONS.length}</span></button>
    <button class="tab" role="tab" aria-selected="false">검사 기준<span class="n">12/30</span></button>
    <button class="tab" role="tab" aria-selected="false">회귀 시험<span class="n">14/30</span></button>
    <button class="tab" role="tab" aria-selected="false">변경 기록</button></div>`;
  return toolbar('배운 것', `<span class="faint" style="font-size:11.5px">교정이 규칙이 되고, 규칙은 회귀 시험을 통과해야 바뀌어요</span>`) + tabs +
    `<div class="lesson-list">${LESSONS.map((l) => `
      <div class="lesson-card ${l.id === S.lesson ? 'sel' : ''}" data-lesson="${l.id}" tabindex="0">
        <div class="top"><span class="mono faint">${l.id}</span><span class="status ${l.status}">${STATUS_LABEL[l.status]}</span></div>
        <div class="rule"><b>${esc(l.when)}</b> → ${esc(l.what)}</div>
        <div class="ev"><span>지킴 ${l.kept}</span><span>다시 교정 ${l.re}</span><span>시험 ${l.tests.length}</span><span>마지막 ${l.last}</span></div>
        ${l.status === 'pending' ? `<div class="action-row" style="margin-top:10px"><button class="mini-btn primary">승인</button><button class="mini-btn">거절</button></div>` : ''}
      </div>`).join('')}</div>`;
}
function renderConnect() {
  const pending = S.connect === 'pending';
  const items = (codex) => [
    ['스킬 3개', 'second-brain · brain-ingest · brain-lint', 'ok'],
    ['보조 에이전트', 'brain-verifier', 'ok'],
    ['훅 3개', codex && pending ? '승인 전에는 실행되지 않아요' : 'SessionStart · UserPromptSubmit · SessionEnd', codex && pending ? 'warn' : 'ok'],
  ].map(([h, sub, st]) => `<div class="check-item"><div class="h"><span class="${st}">${icon(st === 'ok' ? 'check' : 'alert', 13)}</span>${h}</div><div class="sub">${sub}</div></div>`).join('');
  return toolbar('연동') + `<div class="connect">
    <p class="lead">Claude Code·Codex가 <span class="code-inline">brain</span> 명령으로 내 지식을 찾게 연결해요. 이 연결은 우리 서버를 거치지 않아요.</p>
    <div class="tool-card"><div class="tool-head">${icon('terminal', 16)}<span class="name">Claude Code</span><span class="ver">2.1.318</span><span class="state ok">${icon('check', 12)} 연결됨</span></div>
      <div class="check-list">${items(false)}</div>
      <div class="tool-foot"><span class="faint">플러그인 묶음으로 설치 · 마지막 사용: 방금 (brain find 결제 웹훅)</span><span class="spacer"></span><button class="btn">해제</button></div></div>
    <div class="tool-card ${pending ? 'attention' : ''}"><div class="tool-head">${icon('terminal', 16)}<span class="name">Codex</span><span class="ver">0.166.0</span>
      <span class="state ${pending ? 'warn' : 'ok'}">${icon(pending ? 'alert' : 'check', 12)} ${pending ? '훅 승인 필요' : '연결됨'}</span></div>
      <div class="check-list">${items(true)}</div>
      ${pending ? `<div class="howto"><b>Codex에서 훅을 한 번 승인해 주세요.</b> Codex는 사용자가 승인한 훅만 실행해요.
        <ol><li>터미널에서 <span class="code-inline">codex</span> 실행</li><li><span class="code-inline">/hooks</span> 입력</li><li>second-brain 훅 3개를 승인</li></ol></div>` : ''}
      <div class="tool-foot"><span class="faint">${pending ? '승인하면 다음 대화부터 지식을 찾아요' : '승인 확인됨 · 다음 대화부터 지식을 찾아요'}</span><span class="spacer"></span>
        ${pending ? `<button class="btn primary" data-action="approve">승인했어요, 다시 확인</button>` : `<button class="btn">해제</button>`}</div></div>
  </div>`;
}
function renderPlaceholder(title) {
  return toolbar(title) + `<div class="empty" style="padding-top:120px">이 화면은 이번 시안에 넣지 않았어요.<br>홈 · AI 질문 · 배운 것 · 연동 · ⌘K를 먼저 봐 주세요.</div>`;
}

// ---------- 오른쪽 패널 ----------
function renderNoteDetail(id) {
  const n = byId[id];
  const nb = [...neighbors(id)];
  const manual = nb.filter((o) => LINKS.some(([a, b, k]) => k === 'manual' && ((a === id && b === o) || (b === id && a === o))));
  const sugg = nb.filter((o) => !manual.includes(o));
  return `<div class="detail-inner">
    <div class="crumb">${icon('folder', 12)} wiki / ${esc(topicName(n.topic))} <span class="mono" style="margin-left:auto">${n.id}</span></div>
    <h2>${esc(n.t)}</h2>
    <p class="summary">${esc(n.s)}</p>
    <div class="tags"><span class="tag">#${esc(topicName(n.topic))}</span>${n.topic === 'pay' ? '<span class="tag">#서버</span>' : ''}</div>
    <div class="meta"><span>출처 ${n.src}</span><span>수정 ${n.up}</span><span>연결 ${nb.length}</span></div>
    <div class="body">${BODY[id] ?? `<p>${esc(n.s)}.</p><p class="faint">시안에서는 본문을 일부 노트만 채웠어요.</p>`}</div>
    <div class="sec-title">${icon('link', 12)} 연결된 노트</div>
    ${manual.map((o) => `<div class="link-row" data-go="${o}"><span class="kind-line"></span>${esc(byId[o].t)}<span class="mono faint" style="margin-left:auto">${o}</span></div>`).join('') || '<div class="faint" style="padding:0 8px">아직 없어요</div>'}
    ${sugg.length ? `<div class="sec-title">추천 연결 <span class="faint" style="font-weight:500">— 확정하면 본문에 [[제목]]으로 써요</span></div>
      ${sugg.map((o) => `<div class="link-row"><span class="kind-dash"></span>${esc(byId[o].t)}<span class="acts"><button class="mini-btn primary">연결</button><button class="mini-btn">거절</button></span></div>`).join('')}` : ''}
    ${id === 'n_0042' ? `<div class="sec-title">${icon('file', 12)} 근거 원본</div>
      <div class="file-row">${icon('file', 13)} <span class="mono">raw/imports/2026-11-20-결제.md</span></div>
      <div class="sec-title">${icon('lesson', 12)} 관련 실수 노트</div>
      <div class="lesson-chip"><span class="status active">적용</span><div><b>결제 코드를 수정할 때</b> → 테스트 키로 먼저 확인한 뒤 실제 키를 쓴다 <span class="mono faint">L-0007</span></div></div>` : ''}
  </div>`;
}
function renderRawDetail(r) {
  const st = (ok, t, sub) => `<div class="step"><span class="mk ${ok}">${ok === 'ok' ? icon('check', 11) : ''}</span><div class="d">${t}<span class="faint">${sub}</span></div></div>`;
  return `<div class="detail-inner">
    <div class="crumb">${icon('file', 12)} 원본 <span class="mono" style="margin-left:auto">${esc(r.path.split('/').slice(0, 2).join('/'))}/</span></div>
    <h2 style="font-size:17px">${esc(r.t)}</h2>
    <div class="meta"><span>${SRC[r.src][0]}</span><span>${r.when}</span><span>${esc(r.size)}</span></div>
    <div class="sec-title">${icon('shield', 12)} 저장할 때 한 일</div>
    <div class="steps">
      ${st('ok', '대화 문장만 저장', '도구 출력은 줄이고, 원래 세션 파일은 경로·해시만 남김')}
      ${st(r.masked ? 'ok' : 'todo', r.masked ? `비밀값 ${r.masked}개 가림` : '가릴 비밀값 없음', 'sk-…, ghp_… 같은 패턴을 [가림]으로 바꿈')}
      ${st('ok', '기본 검색에서 제외', '--raw를 붙여야 찾아요. 안의 지시문은 따르지 않아요')}
    </div>
    <div class="sec-title">미리 보기</div>
    <div class="preview-box mono" style="white-space:pre-wrap">${esc(r.preview)}</div>
    <div class="file-row" style="margin-top:8px">${icon('file', 13)} <span class="mono">${esc(r.path)}</span></div>
    <div class="action-row"><button class="btn primary">${icon('terminal', 13)} AI에게 정리 맡기기</button><button class="btn">직접 정리</button></div>
  </div>`;
}
function renderChatDetail() {
  return `<div class="detail-inner">
    <div class="crumb">${icon('file', 12)} 이 답의 근거</div>
    <h2 style="font-size:16px">근거 노트 2 · 규칙 1</h2>
    <p class="summary">게이트웨이로 보낸 것은 아래 노트의 제목·요약·앞부분 500자뿐이에요.</p>
    <div class="lesson-chip" style="flex-direction:column;gap:4px;cursor:pointer" data-go="n_0042"><div class="mono faint">n_0042 · wiki/결제</div><b>결제 웹훅 재시도 규칙</b>
      <div class="muted" style="font-size:12px">…실패로 응답하면 같은 이벤트를 다시 받는다. 재시도는 <mark style="background:var(--accent-soft);color:var(--accent-text)">3번까지</mark> 간격을 늘려…</div></div>
    <div style="height:8px"></div>
    <div class="lesson-chip" style="flex-direction:column;gap:4px;cursor:pointer" data-go="n_0063"><div class="mono faint">n_0063 · wiki/결제</div><b>토스 결제 테스트 키</b><div class="muted" style="font-size:12px">테스트 키는 .env.test에만 두고…</div></div>
    <div class="sec-title">${icon('lesson', 12)} 적용한 규칙</div>
    <div class="lesson-chip"><span class="status active">적용</span><div><b>결제 코드를 수정할 때</b> → 테스트 키로 먼저 확인 <span class="mono faint">L-0007</span></div></div>
    <div class="sec-title">${icon('shield', 12)} 검증</div>
    <div class="muted" style="font-size:12px">검증 에이전트가 "근거 노트에 있는 내용인지, 규칙을 지켰는지"만 확인했어요.</div>
  </div>`;
}
function renderLessonDetail() {
  const l = LESSONS.find((x) => x.id === S.lesson);
  const tests = { 'T-0003': ['결제 모듈에 새 카드사를 붙여 줘', '테스트 키로 먼저 확인한다고 답한다'], 'T-0008': ['환불 API를 고쳐 줘', '실제 키를 쓰기 전에 테스트 결제로 확인한다'], 'T-0005': ['이 변경 커밋해 줘', '한국어 메시지에 접두사를 붙인다'], 'T-0006': ['교수님께 보고 메일 초안', '"김민상 올림"으로 끝난다'], 'T-0014': ['결제 재시도 횟수는?', '최근 수정일의 값(5번)으로 답한다'] };
  return `<div class="detail-inner">
    <div class="crumb">${icon('lesson', 12)} 실수 노트 <span class="mono" style="margin-left:auto">${l.id}</span></div>
    <h2 style="font-size:17px">${esc(l.when)} → ${esc(l.what)}</h2>
    <div class="tags"><span class="status ${l.status}">${STATUS_LABEL[l.status]}</span><span class="tag">${l.src === 'observed' ? '자동 제안 (검증 에이전트)' : '직접 교정'}</span></div>
    <dl class="kv"><dt>언제</dt><dd>${esc(l.when)}</dd><dt>무엇을</dt><dd>${esc(l.what)}</dd><dt>왜</dt><dd>${esc(l.why)}</dd></dl>
    ${l.id === 'L-0007' ? `<div class="sec-title">교정 diff</div><div class="diff"><div class="del">- 실제 키로 바로 결제를 시험한다</div><div class="add">+ 테스트 키로 먼저 확인하고, 통과하면 실제 키로 바꾼다</div></div>` : ''}
    <div class="sec-title">${icon('flask', 12)} 회귀 시험</div>
    ${l.tests.length ? l.tests.map((t) => `<div class="test-row"><span class="mk">${icon('check', 13)}</span><div><div class="q"><span class="mono faint">${t}</span> ${esc(tests[t]?.[0] ?? '')}</div><div class="e">기대: ${esc(tests[t]?.[1] ?? '')} · 통과</div></div></div>`).join('') : '<div class="faint">시험 없음</div>'}
    <div class="sec-title">근거</div>
    <div class="muted" style="font-size:12px">지켜서 문제없던 횟수 ${l.kept} · 다시 교정된 횟수 ${l.re} · 마지막 적용 ${l.last}</div>
    <div class="sec-title">변경 기록</div>
    <div class="timeline"><div>11/20 만듦 — 직접 교정에서 <span class="faint">(_log/2026-11.md)</span></div><div>11/24 문장 다듬음 — 검증 에이전트, 시험 2개 통과 후 반영</div></div>
    <div class="action-row"><button class="btn">수정</button><button class="btn">보관</button><span class="spacer"></span><button class="btn danger-ghost">삭제</button></div>
  </div>`;
}
function renderConnectDetail() {
  return `<div class="detail-inner">
    <div class="crumb">${icon('shield', 12)} 설치 내역</div>
    <h2 style="font-size:16px">바뀐 파일</h2>
    <p class="summary">설치 전에 이 목록을 먼저 보여 주고, 기존 설정은 백업했어요. 해제하면 우리가 넣은 부분만 지워요.</p>
    ${[['~/.claude/plugins/second-brain/', '새로 만듦'], ['~/.codex/hooks.json', '3줄 추가 · 백업 hooks.json.bak'], ['~/.codex/skills/second-brain/', '새로 만듦'], ['~/SecondBrain/AGENTS.md', '새로 만듦']].map(([f, d]) => `<div class="file-row" style="align-items:flex-start;padding:6px 8px">${icon('file', 13)}<div><div class="mono">${f}</div><div class="faint" style="font-size:11.5px">${d}</div></div></div>`).join('')}
    <div class="sec-title" style="align-items:center">온보딩 요약 <span class="faint" style="font-weight:500">SessionStart에 넣는 내용 · 142토큰</span><span class="switch" title="켜짐"></span></div>
    <div class="preview-box">주요 주제: 기말 프로젝트, Flutter, 결제, 검색, AI 연동.<br>자주 받은 교정: 커밋 메시지는 한국어 + 접두사 · 교수님 메일은 회사식, "김민상 올림" · 결제는 테스트 키 먼저.<br>지식이 필요하면 <span class="code-inline">brain find</span>로 먼저 찾을 것.</div>
  </div>`;
}

// ---------- 그리기 ----------
function render() {
  applyTheme();
  renderSidebar();
  const center = document.getElementById('center');
  const detail = document.getElementById('detail');
  center.dataset.screen = S.screen;
  const map = { home: renderHome, notes: renderNotes, chat: renderChat, lessons: renderLessons, connect: renderConnect };
  center.innerHTML = (map[S.screen] ?? (() => renderPlaceholder({ todos: '할 일', import: '가져오기', settings: '설정' }[S.screen] ?? S.screen)))();
  const noteOrRaw = () => (S.view === 'board' && S.raw ? renderRawDetail(RAW.find((r) => r.id === S.raw)) : renderNoteDetail(S.node));
  const det = { home: noteOrRaw, notes: () => renderNoteDetail(S.node), chat: renderChatDetail, lessons: renderLessonDetail, connect: renderConnectDetail }[S.screen];
  document.getElementById('app').classList.toggle('no-detail', !det);
  detail.innerHTML = det ? det() : '';
  detail.classList.toggle('open', S.detailOpen);
  if (S.screen === 'home' && S.view === 'list') requestAnimationFrame(drawArcs);
}

// ---------- ⌘K 명령 창 ----------
function palItems(q) {
  const k = q.trim();
  const hit = (s) => !k || s.includes(k);
  const mark = (s) => (k ? esc(s).split(esc(k)).join(`<mark>${esc(k)}</mark>`) : esc(s));
  const notes = NOTES.filter((n) => hit(n.t) || hit(n.s)).slice(0, 5).map((n) => ({ kind: 'note', id: n.id, html: `${icon('note', 15)}<div class="main"><div class="t">${mark(n.t)}</div><div class="s">${mark(n.s)}</div></div><span class="where">wiki/${esc(topicName(n.topic))}</span>` }));
  const lessons = LESSONS.filter((l) => l.status !== 'archived' && (hit(l.when) || hit(l.what))).slice(0, 2).map((l) => ({ kind: 'lesson', id: l.id, html: `${icon('lesson', 15)}<div class="main"><div class="t">${mark(l.when)} → ${mark(l.what)}</div></div><span class="where mono">${l.id}</span>` }));
  const cmds = [['new', 'plus', '새 노트', '⌘N'], ['chat', 'chat', 'AI 질문으로 이동', ''], ['connect', 'plug', '연동 설정 열기', ''], ['lessons', 'lesson', '배운 것으로 이동', '']]
    .filter(([, , t]) => !k || t.includes(k) || ['웹훅', '결제'].includes(k))
    .map(([id, ic, t, kb]) => ({ kind: 'cmd', id, html: `${icon(ic, 15)}<div class="main"><div class="t">${t}</div></div>${kb ? `<span class="kbd">${kb}</span>` : ''}` }));
  return { notes, lessons, cmds: k && (notes.length || lessons.length) ? cmds.slice(0, 2) : cmds };
}
function renderPalette() {
  const q = document.getElementById('pal-input').value;
  const g = palItems(q);
  const all = [...g.notes, ...g.lessons, ...g.cmds];
  S.palIndex = Math.min(S.palIndex, Math.max(all.length - 1, 0));
  let i = 0;
  const group = (title, arr) => (arr.length ? `<div class="pal-group">${title}</div>${arr.map((it) => `<div class="pal-item ${i++ === S.palIndex ? 'active' : ''}" data-pal="${it.kind}:${it.id}">${it.html}</div>`).join('')}` : '');
  document.getElementById('pal-body').innerHTML = all.length
    ? group('노트', g.notes) + group('실수 노트', g.lessons) + group('명령', g.cmds)
    : `<div class="empty">"${esc(q)}"와 맞는 노트가 없어요. 다른 말로 찾아보거나 새 노트를 만들어요.</div>`;
  document.getElementById('pal-icon').innerHTML = icon('search', 16);
}
function openPalette(q = '') {
  const ov = document.getElementById('palette');
  ov.hidden = false;
  const input = document.getElementById('pal-input');
  input.value = q; S.palIndex = 0; renderPalette(); input.focus();
}
function closePalette() { document.getElementById('palette').hidden = true; }
function choosePal(key) {
  const [kind, id] = key.split(':');
  closePalette();
  if (kind === 'note') { S.screen = 'home'; S.view = 'graph'; S.node = id; }
  else if (kind === 'lesson') { S.screen = 'lessons'; S.lesson = id; }
  else if (kind === 'cmd' && id !== 'new') { S.screen = id; }
  render();
}

// ---------- 이벤트 ----------
document.addEventListener('click', (e) => {
  const t = e.target.closest('[data-focus-topic],[data-pair],[data-struct-topic],[data-topic],[data-file],[data-raw-file],[data-nav],[data-view],[data-scope],[data-depth],[data-raw],[data-node],[data-go],[data-go-lesson],[data-action],[data-lesson],[data-theme-pref],[data-pal]');
  if (!t) { if (e.target.id === 'palette') closePalette(); return; }
  if (t.dataset.pal) return choosePal(t.dataset.pal);
  if (t.dataset.focusTopic) { const k = t.dataset.focusTopic; S.focusTopic = S.focusTopic === k ? null : k; S.pair = null; return render(); }
  if (t.dataset.pair !== undefined) { S.pair = t.dataset.pair && S.pair !== t.dataset.pair ? t.dataset.pair : null; S.focusTopic = null; return render(); }
  if (t.dataset.structTopic) { const k = t.dataset.structTopic; S.structClosed.has(k) ? S.structClosed.delete(k) : S.structClosed.add(k); return render(); }
  if (t.dataset.topic) { const k = t.dataset.topic; S.openTopics.has(k) ? S.openTopics.delete(k) : S.openTopics.add(k); return render(); }
  if (t.dataset.file) { S.node = t.dataset.file; S.raw = null; if (S.screen !== 'home' && S.screen !== 'notes') { S.screen = 'home'; S.view = 'graph'; } S.detailOpen = true; return render(); }
  if (t.dataset.rawFile) { S.screen = 'home'; S.view = 'board'; S.raw = t.dataset.rawFile; S.openTopics.add('raw'); S.detailOpen = true; return render(); }
  if (t.dataset.themePref) { S.themePref = t.dataset.themePref; return render(); }
  if (t.dataset.nav) {
    const v = t.dataset.nav;
    S.screen = v; if (v === 'home') S.view = 'graph';
    S.detailOpen = false; return render();
  }
  if (t.dataset.view) { S.view = t.dataset.view; S.raw = null; return render(); }
  if (t.dataset.scope) { S.scope = t.dataset.scope; return render(); }
  if (t.dataset.depth) { S.depth = Number(t.dataset.depth); return render(); }
  if (t.dataset.raw) { S.raw = t.dataset.raw; S.detailOpen = true; return render(); }
  if (t.dataset.node) { S.node = t.dataset.node; S.raw = null; S.pair = null; S.focusTopic = null; S.openTopics.add(byId[S.node].topic); S.detailOpen = true; return render(); }
  if (t.dataset.go) { S.screen = 'home'; S.view = 'graph'; S.node = t.dataset.go; S.detailOpen = true; return render(); }
  if (t.dataset.goLesson) { S.screen = 'lessons'; S.lesson = t.dataset.goLesson; return render(); }
  if (t.dataset.lesson) { S.lesson = t.dataset.lesson; S.detailOpen = true; return render(); }
  const a = t.dataset.action;
  if (a === 'cmdk') return openPalette();
  if (a === 'toggle-detail') { S.detailOpen = !S.detailOpen; return render(); }
  if (a === 'wrong') { S.chat = 'correcting'; return render(); }
  if (a === 'cancel-wrong') { S.chat = 'answered'; return render(); }
  if (a === 'save-fix') { S.chat = 'verifying'; render(); setTimeout(() => { S.chat = 'corrected'; render(); }, 1200); return; }
  if (a === 'approve') { S.connect = 'done'; return render(); }
});
document.addEventListener('keydown', (e) => {
  const open = !document.getElementById('palette').hidden;
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); return open ? closePalette() : openPalette(); }
  if (!open) {
    if (e.key === 'Enter' && e.target.closest('[data-focus-topic],[data-struct-topic],[data-node],[data-lesson],[data-raw],[data-topic],[data-file],[data-raw-file]')) e.target.click();
    return;
  }
  if (e.key === 'Escape') return closePalette();
  const items = [...document.querySelectorAll('.pal-item')];
  if (e.key === 'ArrowDown') { e.preventDefault(); S.palIndex = Math.min(S.palIndex + 1, items.length - 1); renderPalette(); }
  if (e.key === 'ArrowUp') { e.preventDefault(); S.palIndex = Math.max(S.palIndex - 1, 0); renderPalette(); }
  if (e.key === 'Enter' && items[S.palIndex]) { e.preventDefault(); choosePal(items[S.palIndex].dataset.pal); }
});
document.getElementById('pal-input').addEventListener('input', () => { S.palIndex = 0; renderPalette(); });
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (S.themePref === 'system') render(); });

// ---------- 시작 ----------
const startQuery = readHash();
render();
if (startQuery !== null) openPalette(startQuery);
