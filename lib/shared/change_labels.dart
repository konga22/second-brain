/// 변경 기록(`_log/`) 작업 이름 → 화면 글. 타임라인과 설정의 되돌리기 목록이 같이 쓴다.
/// brain_core가 쓰는 작업을 모두 둔다 (11/13 화면 검토: 설정에 "topic-add 22"가 그대로 보였다).
/// 새 작업을 추가하면 여기에도 넣는다 — 없으면 작업 이름이 그대로 보인다.
const changeActionLabels = {
  'add': '새 노트',
  'update': '고침',
  'write': '고침',
  'rename': '이름 바꿈',
  'relink': '링크 고침',
  'status': '상태',
  'move': '옮김',
  'merge': '합침',
  'delete': '지움',
  'attach': '첨부',
  'topic-add': '주제 만듦',
  'undo': '되돌림',
  'lint-fix': '형식 채움',
  'import': '가져옴',
  'lesson-add': '실수 노트',
  'lesson-status': '실수 노트 상태',
  'lesson-evidence': '규칙 근거',
  'lesson-update': '실수 노트 고침',
  'lesson-edit': '실수 노트 고침',
  'lesson-merge': '실수 노트 합침',
  'lesson-test-remove': '회귀 시험 지움',
  'verifier-add': '검사 기준',
  'todo-suggest': '할 일 제안',
  'todo-accept': '할 일 받음',
  'todo-add': '할 일',
  'todo-done': '할 일 끝',
  'todo-undo': '할 일 되살림',
  'todo-remove': '할 일 지움',
};

/// 작업 이름의 화면 글 (모르는 작업은 이름 그대로).
String changeActionLabel(String action) => changeActionLabels[action] ?? action;
