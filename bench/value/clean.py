"""VALUE_DIR=<작업 폴더> python3 bench/value/clean.py <원본 jsonl> <거른 jsonl>

오염 거르기: 다른 조건의 자료(노트 사본·통째 CLAUDE.md·지식 폴더 사본)나 실제 지식 폴더를 읽으려 한 실행, 시험 폴더 위쪽 전체를 뒤진 실행을 뺀다."""
import json, re, sys
import os
CMP = os.environ['VALUE_DIR'].rstrip('/')
SES = os.path.dirname(CMP)
anc = {'/', '/private', '/private/tmp', '/tmp', '/private/tmp/claude-501', '/tmp/claude-501',
       os.path.dirname(SES), SES, CMP}
own = {'A': [CMP + '/wA'], 'B': [CMP + '/wB', CMP + '/notes'], 'C': [CMP + '/wC'], 'D': [CMP + '/wD']}
def paths(t):
    name, _, js = t.partition(':')
    try:
        i = json.loads(js)
    except Exception:
        i = {'command': js}
    out = [i[k] for k in ('path', 'file_path') if k in i]
    if str(i.get('pattern', '')).startswith('/'):
        out.append(i['pattern'])
    if 'command' in i:
        cmd = i['command'].replace('\\ ', ' ')
        out += re.findall(r'(/(?:private/)?tmp(?:/[^\s"\'|;&<>*]+)*)', cmd)
    return out
def norm(p):
    p = p.replace('\\ ', ' ').split('/**')[0].split('/*')[0].rstrip('\\/') or '/'
    return '/private' + p if p.startswith('/tmp') else p
def why(r):
    c = r['cond']; res = []
    for t in r['tools']:
        for p in paths(t):
            q = norm(p)
            if re.search(re.escape(os.path.expanduser('~/SecondBrain')) + r'|/Volumes/SecondBrain', p): res.append(('real', p))
            elif q in anc: res.append(('wide', q))
            elif q.startswith('/private/tmp'):
                if not any(q == o or q.startswith(o + '/') for o in own[c]) and not q.startswith('/private/tmp/x'):
                    res.append(('other', q))
    if c == 'A' and re.search(r'cmp/|n_\d{4}|세컨드 ?브레인 노트', r['ans']): res.append(('ans', ''))
    return res
if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    keep, drop = [], 0
    for l in open(src):
        r = json.loads(l)
        w = [] if r.get('error') else why(r)
        if r.get('error') or w:
            drop += 1; print('DROP', r['set'], r['id'], r['cond'], r['rep'], w[:1] if w else 'error')
        else:
            keep.append(r)
    open(dst, 'w').write(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in keep))
    print(len(keep), 'keep', drop, 'drop')
