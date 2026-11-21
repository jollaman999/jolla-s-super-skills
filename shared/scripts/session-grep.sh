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
#      SESSION_GREP_ENGINE=python|jq  찾는 엔진을 고정한다 (기본: 실제로 도는 python, 없으면 jq)
# exit: 0=매치 있음  1=매치 없음  2=확인 불가(기록 디렉터리 없음, python·jq 둘 다 없음, 정규식 오류)
#
# 엔진: python3·python·py 를 차례로 실제 실행해 보고 되는 것을 쓴다. Windows Store 의 python
#   스텁은 command -v 는 통과하지만 실행하면 exit 49 로 끝나서 실행으로 가린다. 없으면 jq 로 돈다.
#   jq 판은 옵션·필터가 python 판과 같고, 정규식만 python re 대신 jq 의 Oniguruma 문법이다
#   (예: python 의 (?P<이름>...) 은 jq 에서 (?<이름>...)). jq 로 돌면 끝 줄에 그렇다고 적는다.
#
# 왜 스크립트인가 - 매번 즉석에서 짜면 필터를 틀린다. 실제로 겪은 오답들:
#   * thinking 블록의 base64 signature 가 검색어에 걸려 856건이 잡힌 적이 있다
#   * tool_result 를 "사용자 발화" 로 세어 명령 출력이 사람 말로 둔갑한 적이 있다
#   * 프로젝트 디렉터리가 '-' 로 시작해서 find/du 가 옵션으로 먹고 조용히 0건을 냈다
# 이 셋을 여기서 한 번만 막는다.
set -uo pipefail

usage() { sed -n '2,28p' "$0"; }

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
    -h|--help)    usage; exit 0 ;;
    -*)           echo "모르는 옵션: $1" >&2; exit 2 ;;
    *)            [ -z "$PAT" ] && PAT="$1" || { echo "패턴은 하나만" >&2; exit 2; }; shift ;;
  esac
done
[ -n "$PAT" ] || { usage; exit 2; }
case "$ROLE" in user|assistant|both) ;; *) echo "모르는 역할: $ROLE (user | assistant | both)" >&2; exit 2 ;; esac
for n in "$CTX" "$MAX"; do
  case "$n" in ''|*[!0-9]*) echo "숫자가 아닙니다: $n" >&2; exit 2 ;; esac
done

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
ROOT="$CFG/projects"
[ -d "$ROOT" ] || { echo "확인 불가: 세션 기록이 없습니다 ($ROOT)" >&2; exit 2; }

# command -v 만으로는 못 가린다 (Windows Store 스텁). 실제로 돌려 본다.
ENGINE="${SESSION_GREP_ENGINE:-}"
PY=""
if [ "$ENGINE" != jq ]; then
  for c in python3 python py; do
    command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1 && { PY="$c"; break; }
  done
fi
JQ=()
if [ -z "$PY" ] && [ "$ENGINE" != python ]; then
  command -v jq >/dev/null 2>&1 && jq -n 'empty' >/dev/null 2>&1 && JQ=(jq)
  # Windows 판 jq.exe 는 -b 가 없으면 줄끝을 CRLF 로 낸다. -b 를 모르는 jq 에는 안 붙인다
  [ ${#JQ[@]} -gt 0 ] && jq -b -n 'empty' >/dev/null 2>&1 && JQ=(jq -b)
fi
if [ -z "$PY" ] && [ ${#JQ[@]} -eq 0 ]; then
  case "$ENGINE" in
    python) echo "확인 불가: 실행되는 python 이 없습니다 (python3, python, py)" >&2 ;;
    jq)     echo "확인 불가: 실행되는 jq 가 없습니다" >&2 ;;
    *)      echo "확인 불가: 실행되는 python(python3, python, py)도 jq 도 없습니다" >&2 ;;
  esac
  exit 2
fi

# ---------------------------------------------------------------- python 판
if [ -n "$PY" ]; then
PAT="$PAT" ROLE="$ROLE" CTX="$CTX" SINCE="$SINCE" UNTIL="$UNTIL" \
MAX="$MAX" LIST="$LIST" FULL="$FULL" DUMP="$DUMP" ROOT="$ROOT" \
PROJ_FILTER="$(printf '%s\n' ${PROJ[@]+"${PROJ[@]}"})" \
"$PY" - <<'PY'
import os, re, json, glob, sys

root   = os.environ['ROOT']
try:
    pat = re.compile(os.environ['PAT'])
except re.error as e:
    print(f"확인 불가: 정규식 오류 ({e})", file=sys.stderr)
    sys.exit(2)
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
# 아래 jq 판의 not_human 과 같이 고친다.
NOT_HUMAN = ('<command-message>', '<command-name>', '<task-notification>',
             '<local-command-caveat>', '<local-command-stdout>', '<system-reminder>',
             'This session is being continued', 'Base directory for this skill',
             'Caveat: The messages below', '[Request interrupted')

# 출력에 비밀번호를 내지 않는다. 검색 결과는 그대로 이 세션 기록에 다시 남기 때문이다.
# 키워드 뒤 값, "계정 / 값", "user@host 값" 꼴만 본다. 글자만으로 된 낱말은 코드·문장이라 안 가린다.
# 아래 jq 판의 mask 와 같이 고친다.
SECRET = [
    re.compile(r'((?:비번|비밀번호|패스워드|암호|password|passwd|pw|SSHPASS|token|토큰)\s*(?:은|는|:|=)?\s*[\'"]?)([^\s\'"`,)]{4,})', re.I),
    re.compile(r'(\b(?:root|admin|administrator|superadmin|ubuntu|deploy)\s*/\s*)([^\s\'"`,)/]{4,})'),
    re.compile(r'(\b[\w.-]+@[\w.-]+\s+)([^\s\'"`,)/]{6,})(?=\s)'),
]
def secretish(v):
    return bool(re.search(r'[A-Za-z가-힣]', v) and re.search(r'[\d!@#$%^&*_+=-]', v))
def mask(t):
    for rx in SECRET:
        t = rx.sub(lambda m: m.group(1) + ('***' if secretish(m.group(2)) else m.group(2)), t)
    return t

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
                hits.append((ts, proj, sid + sub, o['type'], mask(body)))
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
  rc=$?
  # 0·1·2 밖(인터프리터가 도중에 죽음 등)이 "없음" 으로 읽히면 안 된다
  [ "$rc" -le 2 ] && exit "$rc"
  echo "확인 불가: $PY 가 exit $rc 로 끝났습니다" >&2
  exit 2
fi

# ---------------------------------------------------------------- jq 판
# 1단계: 파일마다 줄을 읽어 매치 하나를 [ts, 프로젝트, 세션, 역할, 본문, 파일] 한 줄로 낸다.
# 2단계: 모아서 python 판과 같은 순서로 정렬해 낸다.
# 파일은 "./<프로젝트>/..." 로 넘긴다. 프로젝트 디렉터리가 '-' 로 시작해도 jq 가 옵션으로 먹지 않는다.
# 줄은 -R 로 받아 fromjson? 으로 푼다. 깨진 줄 하나에 나머지가 멈추지 않게 한다 (python 판의 continue).
JQ_SCAN=$(cat <<'JQ'
# 위 python 판의 NOT_HUMAN 과 같이 고친다.
def not_human:
  . as $t
  | any(("<command-message>", "<command-name>", "<task-notification>",
         "<local-command-caveat>", "<local-command-stdout>", "<system-reminder>",
         "This session is being continued", "Base directory for this skill",
         "Caveat: The messages below", "[Request interrupted"); . as $p | $t | startswith($p));
# 위 python 판의 SECRET·secretish 와 같이 고친다.
def secretish: test("[A-Za-z가-힣]") and test("[\\d!@#$%^&*_+=-]");
def keep_or_mask: .a + (if (.b | secretish) then "***" else .b end);
def mask:
  sub("(?<a>(?:비번|비밀번호|패스워드|암호|password|passwd|pw|SSHPASS|token|토큰)\\s*(?:은|는|:|=)?\\s*['\"]?)(?<b>[^\\s'\"`,)]{4,})"; keep_or_mask; "gi")
  | sub("(?<a>\\b(?:root|admin|administrator|superadmin|ubuntu|deploy)\\s*/\\s*)(?<b>[^\\s'\"`,)/]{4,})"; keep_or_mask; "g")
  | sub("(?<a>\\b[\\w.-]+@[\\w.-]+\\s+)(?<b>[^\\s'\"`,)/]{6,})(?=\\s)"; keep_or_mask; "g");
# thinking(서명이 base64 라 오탐)과 tool_result(명령 출력이다. 사람 발화가 아니다)는 뺀다.
def texts($want):
  .content as $c
  | if ($c | type) == "string" then (if $want == "user" then $c else empty end)
    elif ($c | type) != "array" then empty
    elif $want == "user" and any($c[]; type == "object" and .type == "tool_result") then empty
    else $c[] | select(type == "object" and .type == "text") | (.text // "") | select(type == "string")
    end;
def strip: sub("^\\s+"; "") | sub("\\s+$"; "");

inputs as $line
| input_filename as $f
| ($line | fromjson?)
| select(type == "object")
| .type as $ty
| select(any($roles[]; . == $ty))
| ((.timestamp // "") | if type == "string" then . else tostring end | .[:16]) as $ts
| select($since == "" or $ts[:10] >= $since)
| select($until == "" or $ts[:10] <= $until)
| (.message | if type == "object" then . else {} end)
| texts($ty)
| strip
| select(. != "" and (not_human | not))
| . as $t
| [match($pat)] | select(length > 0) | .[0] as $m
| (if $whole then $t
   else
     ([0, $m.offset - $ctx] | max) as $a
     | ($m.offset + $m.length + $ctx) as $e
     | (if $a > 0 then "…" else "" end)
       + ($t[$a:$e] | split("\n") | join(" "))
       + (if $e < ($t | length) then "…" else "" end)
   end) as $body
| ($f | ltrimstr("./")) as $rel
| ($rel | split("/")) as $parts
| [$ts, $parts[0], ($parts[-1][:8] + (if ($rel | contains("/subagents/")) then "/sub" else "" end)),
   $ty, ($body | mask), $rel]
JQ
)

case "$ROLE" in both) ROLES='["user","assistant"]' ;; *) ROLES="[\"$ROLE\"]" ;; esac
WHOLE=false; { [ "$FULL" = 1 ] || [ -n "$DUMP" ]; } && WHOLE=true

# 정규식 오류는 매치 0건과 구별해야 한다. 파일을 읽기 전에 한 번 컴파일해 본다.
if ! ERR=$("${JQ[@]}" -n --arg pat "$PAT" '"" | test($pat)' 2>&1 >/dev/null); then
  echo "확인 불가: 정규식 오류 (${ERR})" >&2; exit 2
fi

TMP=$(mktemp) || { echo "확인 불가: 임시 파일을 못 만듭니다" >&2; exit 2; }
trap 'rm -f "$TMP"' EXIT

# 파일 목록은 python 판과 같은 두 꼴, 같은 정렬(코드포인트 순 = C 로캘 바이트 순)이다.
# -p 는 python 판처럼 기록 디렉터리를 붙인 전체 경로에 부분일치로 건다.
# 파일이 많아도 명령줄 길이에 안 걸리게 xargs 로 나눠 넘긴다.
(
  cd "$ROOT" || exit 2
  shopt -s nullglob
  for f in ./*/*.jsonl ./*/*/subagents/*.jsonl; do
    if [ ${#PROJ[@]} -gt 0 ]; then
      path="$ROOT/${f#./}"; keep=0
      for x in "${PROJ[@]}"; do [[ "$path" == *"$x"* ]] && { keep=1; break; }; done
      [ "$keep" = 1 ] || continue
    fi
    printf '%s\0' "$f"
  done | LC_ALL=C sort -z \
       | xargs -0 -r "${JQ[@]}" -nRc --arg pat "$PAT" --argjson roles "$ROLES" --argjson ctx "$CTX" \
           --arg since "$SINCE" --arg until "$UNTIL" --argjson whole "$WHOLE" "$JQ_SCAN"
) >"$TMP"
rc=$?
[ "$rc" -eq 0 ] || { echo "확인 불가: jq 로 기록을 읽다가 실패했습니다 (exit $rc)" >&2; exit 2; }

NHITS=$(wc -l <"$TMP" | tr -d ' ')
NSESS=$("${JQ[@]}" -r '.[5]' "$TMP" | LC_ALL=C sort -u | wc -l | tr -d ' ')
NOTE="(jq 로 찾음: 실행되는 python 이 없음. 정규식은 Oniguruma 문법)"
found=1; [ "$NHITS" -gt 0 ] && found=0

if [ "$LIST" = 1 ]; then
  "${JQ[@]}" -r '.[5]' "$TMP" | LC_ALL=C sort -u | while IFS= read -r rel; do printf '%s/%s\n' "$ROOT" "$rel"; done
  printf '\n%s개 세션, 매치 %s건  %s\n' "$NSESS" "$NHITS" "$NOTE" >&2
  exit "$found"
fi

# python 판의 hits.sort() 와 같은 키: (ts, 프로젝트, 세션, 역할, 본문)
SORT='[inputs] | sort_by(.[:5])'

if [ -n "$DUMP" ]; then
  "${JQ[@]}" -nrj "$SORT"' | .[] | "### \(.[0]) [\(.[1])/\(.[2])] \(.[3])\n\(.[4])\n\n"' "$TMP" >"$DUMP" \
    || { echo "확인 불가: $DUMP 에 못 씁니다" >&2; exit 2; }
  echo "${NHITS}건 -> $DUMP  (${NSESS}개 세션)  $NOTE"
  exit "$found"
fi

"${JQ[@]}" -nr --argjson max "$MAX" "$SORT"' | .[:$max][] | "### \(.[0]) [\(.[1])/\(.[2])] \(.[3])\n\(.[4])\n"' "$TMP" \
  || { echo "확인 불가: jq 로 결과를 내다가 실패했습니다" >&2; exit 2; }
EXTRA=$(( NHITS - MAX ))
MORE=""; [ "$EXTRA" -gt 0 ] && MORE="  (${EXTRA}건 생략, -m 로 늘리거나 --dump)"
echo "매치 ${NHITS}건 / 세션 ${NSESS}개${MORE}  $NOTE" >&2
exit "$found"
