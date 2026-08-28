#!/usr/bin/env bash
# 지난 Claude 세션 기록에서 발화를 찾는다. "예전에 내가 뭐라고 했었지" 를 답하기 위한 도구다.
#
# usage: session-grep.sh <정규식> [옵션]
#   -p, --project <조각>   프로젝트 디렉터리 이름 부분일치 (여러 번 가능). 기본 전부
#   -r, --role <역할>      user | assistant | both      (기본 user)
#   -c, --context <n>      매치 앞뒤로 보여줄 글자 수   (기본 200)
#   -s, --since <날짜>     YYYY-MM-DD 이후
#   -u, --until <날짜>     YYYY-MM-DD 까지
#   -m, --max <n>          출력할 매치 수 상한          (기본 60)
#   -l, --list             매치된 세션 파일만 나열
#       --full             자르지 않고 발화 전문 출력
#       --dump <파일>      매치된 발화 전문을 파일로 (컨텍스트를 안 태우고 나중에 읽기)
#
# env: CLAUDE_CONFIG_DIR (기본 $HOME/.claude)
# exit: 0=매치 있음  1=매치 없음  2=확인 불가(기록 디렉터리·python3 없음)
#
# 왜 스크립트인가 - 매번 즉석에서 짜면 필터를 틀린다. 실제로 겪은 오답들:
#   * thinking 블록의 base64 signature 가 검색어에 걸려 856건이 잡힌 적이 있다
#   * tool_result 를 "사용자 발화" 로 세어 명령 출력이 사람 말로 둔갑한 적이 있다
#   * 프로젝트 디렉터리가 '-' 로 시작해서 find/du 가 옵션으로 먹고 조용히 0건을 냈다
# 이 셋을 여기서 한 번만 막는다.
set -uo pipefail

PAT=""; ROLE="user"; CTX=200; SINCE=""; UNTIL=""; MAX=60; LIST=0; FULL=0; DUMP=""
PROJ=()
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--project) PROJ+=("$2"); shift 2 ;;
    -r|--role)    ROLE="$2"; shift 2 ;;
    -c|--context) CTX="$2"; shift 2 ;;
    -s|--since)   SINCE="$2"; shift 2 ;;
    -u|--until)   UNTIL="$2"; shift 2 ;;
    -m|--max)     MAX="$2"; shift 2 ;;
    -l|--list)    LIST=1; shift ;;
    --full)       FULL=1; shift ;;
    --dump)       DUMP="$2"; shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    -*)           echo "모르는 옵션: $1" >&2; exit 2 ;;
    *)            [ -z "$PAT" ] && PAT="$1" || { echo "패턴은 하나만" >&2; exit 2; }; shift ;;
  esac
done
[ -n "$PAT" ] || { sed -n '2,20p' "$0"; exit 2; }

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
ROOT="$CFG/projects"
command -v python3 >/dev/null 2>&1 || { echo "확인 불가: python3 가 필요합니다" >&2; exit 2; }
[ -d "$ROOT" ] || { echo "확인 불가: 세션 기록이 없습니다 ($ROOT)" >&2; exit 2; }

PAT="$PAT" ROLE="$ROLE" CTX="$CTX" SINCE="$SINCE" UNTIL="$UNTIL" \
MAX="$MAX" LIST="$LIST" FULL="$FULL" DUMP="$DUMP" ROOT="$ROOT" \
PROJ_FILTER="$(printf '%s\n' ${PROJ[@]+"${PROJ[@]}"})" \
python3 - <<'PY'
import os, re, json, glob, sys

root   = os.environ['ROOT']
pat    = re.compile(os.environ['PAT'])
role   = os.environ['ROLE']
ctx    = int(os.environ['CTX'])
since  = os.environ['SINCE']
until  = os.environ['UNTIL']
maxn   = int(os.environ['MAX'])
listf  = os.environ['LIST'] == '1'
full   = os.environ['FULL'] == '1'
dump   = os.environ['DUMP']
filt   = [p for p in os.environ['PROJ_FILTER'].split('\n') if p]

# 사람이 친 발화가 아닌 것들. 스킬 주입·커맨드 래퍼·요약 이어붙임은 검색 대상이 아니다.
NOT_HUMAN = ('<command-message>', '<command-name>', '<task-notification>',
             '<local-command-caveat>', '<local-command-stdout>', '<system-reminder>',
             'This session is being continued', 'Base directory for this skill',
             'Caveat: The messages below', '[Request interrupted')

def texts(msg, want):
    """검색 대상 텍스트만 뽑는다. thinking(서명이 base64 라 오탐)과 tool_result 는 뺀다."""
    c = msg.get('content')
    if isinstance(c, str):
        return [c] if want == 'user' else []
    if not isinstance(c, list):
        return []
    if want == 'user' and any(isinstance(b, dict) and b.get('type') == 'tool_result' for b in c):
        return []   # 명령 출력이다. 사람 발화가 아니다.
    return [b.get('text', '') for b in c if isinstance(b, dict) and b.get('type') == 'text']

files = sorted(glob.glob(os.path.join(root, '*', '*.jsonl')) +
               glob.glob(os.path.join(root, '*', '*', 'subagents', '*.jsonl')))
if filt:
    files = [f for f in files if any(x in f for x in filt)]

want_roles = ('user', 'assistant') if role == 'both' else (role,)
hits, seen_files = [], []

for f in files:
    proj = os.path.relpath(f, root).split(os.sep)[0]
    sid  = os.path.basename(f)[:8]
    sub  = '/sub' if '/subagents/' in f.replace(os.sep, '/') else ''
    matched_here = False
    try:
        fh = open(f, encoding='utf-8', errors='replace')
    except OSError:
        continue
    with fh:
        for line in fh:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get('type') not in want_roles:
                continue
            ts = (o.get('timestamp') or '')[:16]
            if since and ts[:10] < since:  continue
            if until and ts[:10] > until:  continue
            for t in texts(o.get('message') or {}, o['type']):
                t = t.strip()
                if not t or t.startswith(NOT_HUMAN):
                    continue
                m = pat.search(t)
                if not m:
                    continue
                matched_here = True
                if full or dump:
                    body = t
                else:
                    a = max(0, m.start() - ctx)
                    body = ('…' if a else '') + t[a:m.end() + ctx].replace('\n', ' ')
                    if m.end() + ctx < len(t):
                        body += '…'
                hits.append((ts, proj, sid + sub, o['type'], body))
    if matched_here:
        seen_files.append(f)

hits.sort()

if listf:
    for f in seen_files:
        print(f)
    print(f"\n{len(seen_files)}개 세션, 매치 {len(hits)}건", file=sys.stderr)
    sys.exit(0 if hits else 1)

if dump:
    with open(dump, 'w', encoding='utf-8') as out:
        for ts, proj, sid, ty, body in hits:
            out.write(f"### {ts} [{proj}/{sid}] {ty}\n{body}\n\n")
    print(f"{len(hits)}건 -> {dump}  ({len(seen_files)}개 세션)")
    sys.exit(0 if hits else 1)

for ts, proj, sid, ty, body in hits[:maxn]:
    print(f"### {ts} [{proj}/{sid}] {ty}")
    print(body)
    print()
extra = len(hits) - maxn
print(f"매치 {len(hits)}건 / 세션 {len(seen_files)}개" + (f"  ({extra}건 생략, -m 로 늘리거나 --dump)" if extra > 0 else ""),
      file=sys.stderr)
sys.exit(0 if hits else 1)
PY
