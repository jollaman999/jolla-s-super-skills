#!/usr/bin/env bash
# 규칙을 지키는지 실제 세션을 돌려서 확인한다.
#
# 케이스마다 임시 폴더를 만들고 이 repo 를 그 안에 설치한 뒤,
# claude -p 로 세션을 한 번 돌리고 무슨 도구를 썼는지 기록에서 확인한다.
#
# usage: verify-impl/evals/run.sh [케이스 ...] [--keep] [--model M] [--turns N] [--timeout S]
#   케이스     : 이름만 준다 (E1 E2). 안 주면 cases/ 안의 전부
#   --keep     : 임시 폴더를 안 지운다. 기록을 직접 볼 때
#   --reps     : 케이스마다 N 번 돌린다. 안 주면 물어본다 (터미널이 아니면 1회)
#   --model    : 모델을 고정한다. 안 주면 설정된 기본값
#   --turns    : 세션 최대 턴 수 (기본 30). 모자라면 답변 전에 잘린다
#   --timeout  : 세션 하나의 제한 시간, 초 (기본 420)
#   --jobs     : 케이스를 몇 개까지 동시에 돌릴지 (기본 1). 많이 띄우면 느려져 제한 시간에 걸린다
#
# exit: 0=전부 통과  1=규칙 실패 있음  2=사용법 오류 또는 세션을 못 돌림
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"
CASEDIR="$HERE/cases"

KEEP=0; MODEL=""; TURNS=30; LIMIT=420; REPS=1; REPS_SET=0; JOBS=1; WANT=()

usage() { sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --keep)    KEEP=1 ;;
    --reps)    shift; REPS="${1:-1}"; REPS_SET=1 ;;
    --model)   shift; MODEL="${1:-}" ;;
    --turns)   shift; TURNS="${1:-30}" ;;
    --timeout) shift; LIMIT="${1:-420}" ;;
    --jobs)    shift; JOBS="${1:-1}" ;;
    -h|--help) usage; exit 0 ;;
    -*)        usage >&2; exit 2 ;;
    *)         WANT+=("$1") ;;
  esac
  shift
done

command -v claude >/dev/null || { echo "claude 가 PATH 에 없습니다" >&2; exit 2; }
command -v jq     >/dev/null || { echo "jq 가 없습니다" >&2; exit 2; }

# 로그인 정보는 설치본에서 가져와 임시 폴더에 넣는다. 없으면 세션이 "Not logged in" 으로 끝난다.
CREDS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"

# 실행할 케이스 목록
if [ "${#WANT[@]}" -eq 0 ]; then
  for f in "$CASEDIR"/*.txt; do
    [ -e "$f" ] || continue
    WANT+=("$(basename "$f" .txt)")
  done
fi
[ "${#WANT[@]}" -gt 0 ] || { echo "케이스가 없습니다: $CASEDIR" >&2; exit 2; }

# 몇 번 돌릴지는 사람이 정한다. 세션 하나에 몇 분씩 걸리고 토큰을 쓰기 때문에
# 기본값으로 여러 번 도는 일이 없어야 한다.
# --reps 를 줬으면 묻지 않는다. 터미널이 아니면(파이프·CI·백그라운드) 1회로 간다.
if [ "$REPS_SET" -eq 0 ]; then
  if [ -t 0 ]; then
    printf '케이스 %d개. 몇 번씩 돌릴까요? (1=빠름, 3~5=흔들리는지 확인) [1]: ' "${#WANT[@]}"
    read -r ans
    case "$ans" in
      ''|*[!0-9]*) REPS=1 ;;
      *)           REPS=$ans ;;
    esac
    [ "$REPS" -lt 1 ] && REPS=1
    printf '세션 %d개, 대략 %d분 걸립니다. 멈추려면 Ctrl-C.\n\n' \
      "$((${#WANT[@]} * REPS))" "$((${#WANT[@]} * REPS * 3))"
  else
    REPS=1
  fi
fi

# 프롬프트 파일을 --- 줄로 잘라 메시지 하나씩 NUL 로 구분해 낸다
split_messages() {
  awk '/^---$/ { printf "%s%c", buf, 0; buf=""; next }
       { buf = buf $0 "\n" }
       END { printf "%s%c", buf, 0 }' "$1"
}

# 케이스의 메시지를 순서대로 보낸다. 두 번째부터는 --resume 으로 같은 세션에 이어붙인다.
# 기록은 턴별 파일로 남기고 <out> 에 이어 붙인다.
run_session() { # <프롬프트파일> <proj> <cfg> <out>
  local txt="$1" proj="$2" cfg="$3" out="$4"
  local -a base=(--output-format stream-json --verbose
                 --max-turns "$TURNS" --dangerously-skip-permissions)
  [ -n "$MODEL" ] && base+=(--model "$MODEL")
  local n=0 sid="" part msg
  : >"$out"
  # claude 의 stdin 을 /dev/null 로 막는다. 안 막으면 아래 while 이 읽는
  # 메시지 목록을 claude 가 먹어버려 두 번째 턴부터 실행되지 않는다.
  while IFS= read -r -d '' msg; do
    [ -n "$(printf '%s' "$msg" | tr -d '[:space:]')" ] || continue
    n=$((n+1)); part="$out.$n"
    if [ "$n" -eq 1 ]; then
      ( cd "$proj" && CLAUDE_CONFIG_DIR="$cfg" timeout "$LIMIT" claude -p "$msg" "${base[@]}" ) >"$part" 2>&1 </dev/null
      sid=$(jq -r 'select(.type=="system" and .subtype=="init") | .session_id' "$part" 2>/dev/null | head -1)
    else
      [ -n "$sid" ] || break
      ( cd "$proj" && CLAUDE_CONFIG_DIR="$cfg" timeout "$LIMIT" claude -p --resume "$sid" "$msg" "${base[@]}" ) >"$part" 2>&1 </dev/null
    fi
    cat "$part" >>"$out"
  done < <(split_messages "$txt")
}

# 도구 호출 하나가 TSV 한 줄이어야 해서 명령 안의 줄바꿈을 이 표식으로 바꿔 둔다.
# 공백으로 눌러버리면 줄 구조가 사라져 heredoc 본문을 못 가려낸다.
# 탭은 TSV 구분자라 못 쓰고, 눈에 보이는 문자는 명령 본문에 그대로 나올 수 있어 못 쓴다.
NLMARK=$'\001'

# stream-json 에서 도구 호출만 순서대로 뽑는다
tool_calls() {
  jq -r --arg nl "$NLMARK" 'select(.type=="assistant") | .message.content[]?
         | select(.type=="tool_use")
         | [.name, ((.input.command // .input.file_path // .input.skill // .input.prompt // "") | tostring | gsub("\n";$nl))]
         | @tsv' "$1" 2>/dev/null
}

# 고친 파일이 샌드박스 밖인가. 상대경로는 프로젝트 폴더 기준이라 안쪽이다.
outside_sandbox() { # <샌드박스> <경로>
  case "$2" in
    /*) case "$2" in "$1"/*) return 1 ;; *) return 0 ;; esac ;;
    *)  return 1 ;;
  esac
}

# 같은 명령이되 앞에 timeout 이 반드시 붙은 형태
cmd_regex_timeout() {
  printf '(^|[;&|(`{]|[$]\\()[[:space:]]*((do|then|else|elif|nohup|env|sudo|xargs)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*timeout[[:space:]]+[0-9]+[a-z]*[[:space:]]+(sudo[[:space:]]+)?%s([[:space:]]|$)' "$1"
}

# 세션이 어떻게 끝났는지. 여러 턴이면 마지막 턴을 본다
session_status() {
  jq -rs 'map(select(.type=="result")) | last | (.subtype // "none")' "$1" 2>/dev/null
}

# 세션 자체가 실패했는가. 규칙 위반이 아니라 돌리지 못한 것들이다.
#   - 로그인 만료·API 오류: is_error 가 true. "Not logged in" 은 subtype 이
#     success 인 채로 오므로 subtype 만 보면 놓친다.
#   - 시간 초과로 중간에 잘림: result 줄 자체가 없다.
#   - 턴 상한: 답변까지 못 갔다. --turns 를 올릴 일이지 규칙 문제가 아니다.
session_error() {
  local n
  n=$(grep -c '"type":"result"' "$1" 2>/dev/null) || n=0
  if [ "${n:-0}" -eq 0 ]; then
    echo "답변 없이 잘림: --timeout 을 올리세요"
    return
  fi
  jq -rs 'map(select(.type=="result")) as $r
          | ($r | map(select(.is_error == true)) | first) as $bad
          | ($r | last) as $lastr
          | if $bad != null then (($bad.subtype // "error") + ": " + (($bad.result // "") | tostring))
            elif ($lastr.subtype // "") == "error_max_turns" then "턴 상한: --turns 를 올리세요"
            else empty end' "$1" 2>/dev/null
}

# 어떤 팀원(서브에이전트)을 띄웠는가. 기록에 subagent_type 으로 남는다.
agents_used() {
  grep -o '"subagent_type":"[^"]*"' "$1" 2>/dev/null | sed 's/.*:"//; s/"$//' | sort -u
}

# 사람에게 낸 마지막 답변만 뽑는다
final_text() {
  jq -rs 'map(select(.type=="result")) | last | (.result // empty)' "$1" 2>/dev/null
}

# 파일을 고친 도구에서 대상 경로만 뽑는다
edited_paths() {
  jq -r 'select(.type=="assistant") | .message.content[]?
         | select(.type=="tool_use")
         | select(.name=="Edit" or .name=="Write" or .name=="MultiEdit" or .name=="NotebookEdit")
         | (.input.file_path // .input.notebook_path // empty)' "$1" 2>/dev/null
}

# 한 항목 안의 | 는 "이 중 하나면 된다" 는 뜻이다.
# 같은 것을 가리키는 말이 세션마다 달라지기 때문이다 ("unknown" 과 "확인 못 함").
has_any() { # <찾을 대상 글> <후보1|후보2|...>
  local text="$1" alts="$2" a
  local IFS='|'
  for a in $alts; do
    a="$(printf '%s' "$a" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$a" ] || continue
    printf '%s' "$text" | grep -qF -- "$a" && return 0
  done
  return 1
}

# 규칙 파일에서 키 하나의 값을 읽는다
rule_get() {
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | head -1 \
    | sed 's/[[:space:]]*$//'
}

# 명령 이름 하나를 "실제로 실행됐는가" 를 보는 정규식으로 바꾼다.
# 줄 맨 앞이나 ; | & ( ` { $( 뒤, do·then 같은 키워드 뒤,
# sudo·timeout·환경변수 같은 앞붙는 것들 뒤까지 본다.
# sshpass 처럼 뒤에 인자를 받는 감싸개는 못 잡으므로 금지명령에 따로 적는다.
cmd_regex() {
  printf '(^|[;&|(`{]|[$]\\()[[:space:]]*((do|then|else|elif|nohup|env|sudo|xargs)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+|timeout[[:space:]]+[0-9]+[a-z]*[[:space:]]+)*%s([[:space:]]|$)' "$1"
}

# ssh -G(적용될 설정 출력) -V(버전) -Q(알고리즘 목록) 은 접속하지 않는다.
# 줄을 구분자로 쪼개 ssh 가 명령 위치인 조각을 모두 보고, 전부 조회 형태면 접속이 아니다.
# 하나라도 조회 플래그가 없으면 그 조각이 접속을 시도한 것이라 위반으로 남긴다.
ssh_query_only() { # <줄>
  local segs seg found=0
  segs=$(printf '%s' "$1" | tr ';&|`(){}' '\n' | grep -E "$(cmd_regex ssh)")
  [ -n "$segs" ] || return 1
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    found=1
    printf '%s' "$seg" \
      | grep -qE '(^|[[:space:]])-[A-Za-z]*[GVQ][A-Za-z]*([[:space:]]|$)' || return 1
  done <<EOF
$segs
EOF
  [ "$found" = 1 ]
}

# heredoc 본문은 파일에 적어 넣는 글이지 실행이 아니다. 판정 전에 떼어낸다.
# 진행 파일에 "scp ... 로 배포한다" 를 적은 것을 scp 실행으로 세던 오탐 때문이다.
# 줄바꿈은 $NLMARK 로 남아 있으니 셸과 같은 규칙을 쓴다. 여는 <<DELIM 다음 줄부터
# 구분자만 있는 줄까지를 버리고, 여는 줄에서는 <<DELIM 토큰만 뗀다.
# 구분자가 본문 중간에 문장의 일부로 나와도 거기서 안 끊긴다.
# 따옴표 유무와 <<- 와 구분자 이름은 임의로 온다.
# 한 줄에서 <<A <<B 처럼 여럿이 열리면 본문도 그 순서로 온다.
# 닫는 말이 없으면 (잘린 기록) 뒤쪽 전부가 본문이다.
# <<< 는 히어스트링이라 본문이 없으므로 건드리지 않는다.
strip_heredoc() {
  awk -v nl="$NLMARK" '
  {
    n = split($0, seg, nl)
    out = ""; kept = 0; open = 0
    for (i = 1; i <= n; i++) {
      line = seg[i]
      # 본문 안이면 닫는 줄을 찾을 때까지 통째로 버린다.
      # <<- 는 선행 탭을 허용하므로 앞뒤 공백은 떼고 비교한다.
      if (open > 0) {
        t = line
        sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        if (t == delim[1]) {
          for (j = 1; j < open; j++) delim[j] = delim[j+1]
          open--
        }
        continue
      }
      head = ""
      while (match(line, /(^|[^<])<<-?[ \t]*(\047[A-Za-z_][A-Za-z0-9_]*\047|"[A-Za-z_][A-Za-z0-9_]*"|[A-Za-z_][A-Za-z0-9_]*)/)) {
        mt = substr(line, RSTART, RLENGTH)
        p = index(mt, "<<")
        head = head substr(line, 1, RSTART - 1) substr(mt, 1, p - 1) " "
        d = substr(mt, p + 2)
        sub(/^-/, "", d); sub(/^[ \t]*/, "", d); gsub(/\047|"/, "", d)
        open++; delim[open] = d
        line = substr(line, RSTART + RLENGTH)
      }
      out = out (kept++ ? nl : "") head line
    }
    print out
  }'
}

# 케이스를 한 번 돌린다. 결과를 접두사로 구분해 표준출력에 낸다.
#   R:<사유>  실패 사유. 한 줄도 없으면 통과
#   W:<경고>  실패로는 안 세는 것
#   K:<경로>  --keep 일 때 남긴 기록 파일
run_once() { # <케이스이름> <규칙파일> <프롬프트파일>
  local name="$1" rule="$2" txt="$3"
  local sandbox cfg proj out before after status answer calls bash_cmds bash_recs first early hit bare err w c t e line rec
  local -a why warn needs bans bad ban tos leaks exs need want_skills want_agents want_files
  sandbox=$(mktemp -d); cfg="$sandbox/.claude"; proj="$sandbox/proj"
  mkdir -p "$cfg" "$proj"
  [ -f "$CREDS" ] && { cp "$CREDS" "$cfg/.credentials.json"; chmod 600 "$cfg/.credentials.json"; }

  CLAUDE_CONFIG_DIR="$cfg" "$REPO/install.sh" --global --yes >"$sandbox/install.log" 2>&1 || {
    printf 'R:설치 오류 (%s)\n' "$sandbox/install.log"; return; }

  # 케이스가 가짜 프로젝트를 요구하면 만들어 둔다
  ( cd "$proj" && git init -q ) 2>/dev/null
  [ -f "$CASEDIR/$name.setup" ] && ( cd "$proj" && bash "$CASEDIR/$name.setup" ) >/dev/null 2>&1

  # 슬래시로 시작하는 발화는 Claude Code 가 슬래시 명령으로 먹는다.
  # "Unknown command: /nodes" 만 돌아오고 규칙은 시험되지도 않는다.
  if split_messages "$txt" | tr '\0' '\n' | grep -q '^/'; then
    printf 'E:프롬프트가 / 로 시작합니다. 슬래시 명령으로 먹히니 문장을 바꾸세요\n'
    rm -rf "$sandbox"
    return
  fi

  out="$sandbox/out.json"
  before=$(git -C "$REPO" status --porcelain 2>/dev/null | sort)
  run_session "$txt" "$proj" "$cfg" "$out"

  # 규칙을 보기 전에 세션이 제대로 돌았는지부터 본다. 로그인이 풀린 세션의
  # 빈 답변을 "규칙을 안 지켰다" 로 읽으면 그게 무음 실패다.
  err=$(session_error "$out" | head -1)
  if [ -n "$err" ]; then
    printf 'E:%s\n' "$(printf '%s' "$err" | cut -c1-120)"
    printf 'K:%s\n' "$out"
    return
  fi

  calls=$(tool_calls "$out")

  why=(); warn=()

  # 샌드박스 밖 파일을 고쳤으면 실패. 케이스 규칙과 무관하게 항상 본다.
  # 상대경로는 프로젝트 폴더 기준이므로 샌드박스 안이다.
  while IFS= read -r fp; do
    [ -n "$fp" ] || continue
    outside_sandbox "$sandbox" "$fp" && why+=("샌드박스 밖 파일 수정: $fp")
  done <<EOF
$(edited_paths "$out")
EOF

  # Bash 로 우회해서 고치는 것까지는 위 검사로 못 잡는다. repo 워킹트리가
  # 바뀌었으면 알린다. 다른 세션이 만졌을 수도 있어 실패로는 세지 않는다.
  after=$(git -C "$REPO" status --porcelain 2>/dev/null | sort)
  [ "$before" != "$after" ] && warn+=("repo 워킹트리가 바뀜. 이 세션인지 다른 세션인지 확인 필요")

  # 반드시 나와야 하는 skill
  # 쉼표로 여러 개를 적으면 전부 불려야 한다. skill 이 skill 을 부르는 연계를 본다.
  IFS=',' read -ra want_skills <<<"$(rule_get "$rule" "skill")"
  for t in "${want_skills[@]}"; do
    t="${t// /}"; [ -n "$t" ] || continue
    printf '%s\n' "$calls" | grep -q "^Skill	.*$t" \
      || why+=("skill '$t' 을 안 불렀음")
  done

  # 반드시 띄워야 하는 팀원. 팀장이 직접 다 하면 컨텍스트 격리가 무의미하다.
  IFS=',' read -ra want_agents <<<"$(rule_get "$rule" "필수에이전트")"
  for t in "${want_agents[@]}"; do
    t="${t// /}"; [ -n "$t" ] || continue
    agents_used "$out" | grep -qx "$t" || why+=("팀원 '$t' 를 안 띄웠음")
  done

  # 반드시 생겨야 하는 파일. 프로젝트 폴더 기준 상대경로다.
  IFS=',' read -ra want_files <<<"$(rule_get "$rule" "필수파일")"
  for t in "${want_files[@]}"; do
    t="$(printf '%s' "$t" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$t" ] || continue
    [ -e "$proj/$t" ] || why+=("파일 '$t' 이 안 생겼음")
  done

  # 반드시 나와야 하는 도구
  IFS=',' read -ra need <<<"$(rule_get "$rule" "필수도구")"
  for t in "${need[@]}"; do
    t="${t// /}"; [ -n "$t" ] || continue
    printf '%s\n' "$calls" | grep -q "^$t	" || why+=("$t 를 안 썼음")
  done

  # 규칙이 시켜서 하는 일은 위반이 아니다. 예외로 뺀다.
  # 예: .claude/verify-progress.md 갱신은 SKILL.md 가 노드마다 하라고 정해둔 것이다.
  IFS=',' read -ra exs <<<"$(rule_get "$rule" "예외")"
  is_exempt() {
    local line="$1" e
    for e in "${exs[@]}"; do
      e="$(printf '%s' "$e" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$e" ] || continue
      printf '%s' "$line" | grep -qF -- "$e" && return 0
    done
    return 1
  }

  # 나오면 안 되는 도구
  IFS=',' read -ra ban <<<"$(rule_get "$rule" "금지도구")"
  for t in "${ban[@]}"; do
    t="${t// /}"; [ -n "$t" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      is_exempt "$line" && continue
      # 표식이 사람에게 보이는 문구로 새어 나가면 안 된다
      why+=("$t 를 썼음: $(printf '%s' "${line#*	}" | tr "$NLMARK" ' ' | cut -c1-60)")
      break
    done <<EOF
$(printf '%s\n' "$calls" | grep "^$t	")
EOF
  done

  # 나오면 안 되는 명령. 실제로 그 명령을 실행했을 때만 잡는다.
  # ls ~/.ssh 나 grep "ssh config" 처럼 이름만 스쳐가는 것은 위반이 아니다.
  # heredoc 본문에 인용된 것도 실행이 아니라서 여기서 미리 떼어낸다.
  # 본문을 뗀 뒤 표식을 진짜 줄바꿈으로 되돌린다. cmd_regex 가 줄 맨 앞을 앵커로
  # 쓰기 때문에, 표식을 그대로 두면 heredoc 뒤에 이어진 명령을 못 잡는다.
  # $1="" 로 지우면 awk 가 OFS(공백)로 재조립해 줄 맨 앞에 공백이 남고
  # 명령 안의 탭까지 공백으로 바뀐다. 필드를 건드리지 않고 도구 이름만 떼어낸다.
  # bash_recs 는 도구 호출 하나가 한 줄(줄바꿈은 표식). bash_cmds 는 그것을
  # 물리적 줄로 편 것이다. 예외는 호출 단위로, 명령 탐지는 줄 단위로 봐야 한다.
  bash_recs=$(printf '%s\n' "$calls" | awk -F'\t' '$1=="Bash"{ sub(/^[^\t]*\t/, ""); print }' \
              | strip_heredoc)
  bash_cmds=$(printf '%s\n' "$bash_recs" | tr "$NLMARK" '\n')
  IFS=',' read -ra bad <<<"$(rule_get "$rule" "금지명령")"
  for c in "${bad[@]}"; do
    c="$(printf '%s' "$c" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$c" ] || continue
    hit=""
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      # 예외는 도구 호출 단위다. 진행 파일 갱신처럼 규칙이 시킨 일은 그 호출 안
      # 어디에 적혀 있어도 위반이 아니다. 줄 단위로 보면 예외가 다른 줄에 있을 때
      # 놓친다.
      is_exempt "$rec" && continue
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        [ "$c" = "ssh" ] && ssh_query_only "$line" && continue
        hit="$line"; break
      done <<INNER
$(printf '%s' "$rec" | tr "$NLMARK" '\n' | grep -E "$(cmd_regex "$c")")
INNER
      [ -n "$hit" ] && break
    done <<EOF
$bash_recs
EOF
    # 앞 100자만 보이면 어디가 걸렸는지 안 드러나서, 매칭된 조각을 앞에 붙인다
    [ -n "$hit" ] && why+=("금지 명령 실행: [$(printf '%s\n' "$hit" | grep -oE "$(cmd_regex "$c")" | head -1)] $(printf '%s' "$hit" | cut -c1-100)")
  done

  # 답변을 보는 검사는 세션이 끝까지 갔을 때만 뜻이 있다.
  # 턴 상한에 걸려 잘린 것을 "규칙을 안 지켰다" 로 읽으면 그게 무음 실패다.
  status=$(session_status "$out")
  answer=$(final_text "$out")
  if [ "$status" != "success" ]; then
    why+=("세션이 답변 전에 끝남: ${status:-없음}")
    answer=""
  fi

  # 마지막 답변에 있어야 하는 말 / 있으면 안 되는 말
  [ "$status" = "success" ] && IFS=',' read -ra needs <<<"$(rule_get "$rule" "필수문구")" || needs=()
  for w in "${needs[@]}"; do
    w="$(printf '%s' "$w" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$w" ] || continue
    has_any "$answer" "$w" || why+=("응답에 '$w' 가 없음")
  done
  IFS=',' read -ra bans <<<"$(rule_get "$rule" "금지문구")"
  for w in "${bans[@]}"; do
    w="$(printf '%s' "$w" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$w" ] || continue
    has_any "$answer" "$w" && why+=("응답에 '$w' 가 있음")
  done

  # 이 명령들은 timeout 없이 실행하면 안 된다
  IFS=',' read -ra tos <<<"$(rule_get "$rule" "timeout필수")"
  for c in "${tos[@]}"; do
    c="$(printf '%s' "$c" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$c" ] || continue
    bare=$(printf '%s\n' "$bash_cmds" | grep -E "$(cmd_regex "$c")" \
           | grep -Ev "$(cmd_regex_timeout "$c")" | head -1)
    [ -n "$bare" ] && why+=("timeout 없이 $c 실행: $(printf '%s' "$bare" | cut -c1-100)")
  done

  # 이 문자열은 답변에도, 샌드박스가 만든 파일에도 남으면 안 된다
  IFS=',' read -ra leaks <<<"$(rule_get "$rule" "유출금지")"
  for w in "${leaks[@]}"; do
    w="$(printf '%s' "$w" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$w" ] || continue
    printf '%s' "$answer" | grep -qF -- "$w" && why+=("답변에 '$w' 가 남음")
    hit=$(grep -rlF -- "$w" "$proj" 2>/dev/null | head -1)
    [ -n "$hit" ] && why+=("파일에 '$w' 가 남음: ${hit#$sandbox/}")
  done

  # skill 을 부르기 전에 다른 도구를 썼는지
  if [ "$(rule_get "$rule" "skill먼저")" = "예" ]; then
    first=$(printf '%s\n' "$calls" | grep -n "^Skill	" | head -1 | cut -d: -f1)
    if [ -z "$first" ]; then
      why+=("skill 을 아예 안 불렀음")
    else
      early=$(printf '%s\n' "$calls" | head -n "$((first-1))" \
              | grep -v "^TodoWrite	" | grep -v "^Skill	" | head -1)
      [ -n "$early" ] && why+=("skill 보다 먼저 ${early%%	*} 를 씀")
    fi
  fi

  local r
  for r in "${why[@]:-}";  do [ -n "$r" ] && printf 'R:%s\n' "$r"; done
  for r in "${warn[@]:-}"; do [ -n "$r" ] && printf 'W:%s\n' "$r"; done
  # 실패한 회차의 기록은 --keep 없이도 남긴다. 기록이 필요해지는 시점은
  # 실패를 본 뒤인데, 그때 지워져 있으면 같은 것을 또 돌려야 한다.
  if [ "$KEEP" -eq 1 ] || [ "${#why[@]}" -gt 0 ]; then
    printf 'K:%s\n' "$out"
  else
    rm -rf "$sandbox"
  fi
}

# 케이스 하나를 REPS 번 돌리고 표시용 출력을 낸다.
# 마지막 줄은 STATUS:pass|fail|err 로, 부모가 집계에 쓴다.
run_case() { # <케이스이름>
  local name="$1" txt rule desc ran verdict st
  local ok=0 ng=0 errs="" reasons="" warns="" keeps="" rep=1 result es rs
  txt="$CASEDIR/$name.txt"; rule="$CASEDIR/$name.rule"
  if [ ! -f "$txt" ] || [ ! -f "$rule" ]; then
    printf '%s  건너뜀 (프롬프트나 규칙 파일 없음)\n' "$name"
    printf 'STATUS:skip\n'; return
  fi
  desc=$(rule_get "$rule" "설명")
  while [ "$rep" -le "$REPS" ]; do
    result=$(run_once "$name" "$rule" "$txt")
    es=$(printf '%s\n' "$result" | sed -n 's/^E://p')
    rs=$(printf '%s\n' "$result" | sed -n 's/^R://p')
    if [ -n "$es" ]; then
      errs="$errs$es
"
    elif [ -z "$rs" ]; then ok=$((ok+1)); else ng=$((ng+1)); reasons="$reasons$rs
"; fi
    warns="$warns$(printf '%s\n' "$result" | sed -n 's/^W://p')
"
    keeps="$keeps$(printf '%s\n' "$result" | sed -n 's/^K://p')
"
    rep=$((rep+1))
  done

  # 판정은 실제로 돌아간 횟수 기준이다. 돌리지 못한 회차는 분모에서 뺀다.
  ran=$((ok+ng))
  if [ "$ran" -eq 0 ]; then
    verdict="돌리지 못함"; st=err
  elif [ "$REPS" -eq 1 ]; then
    if [ "$ok" -eq 1 ]; then verdict="통과"; st=pass; else verdict="실패"; st=fail; fi
  else
    verdict="$ok/$ran 통과"
    [ "$ran" -lt "$REPS" ] && verdict="$verdict ($((REPS-ran))회는 못 돌림)"
    if [ "$ng" -eq 0 ]; then st=pass; else st=fail; fi
  fi
  printf '%-4s %-34s %s\n' "$name" "$desc" "$verdict"

  # 같은 사유가 여러 번 나오면 한 줄로 합친다
  printf '%s' "$reasons" | grep -v '^$' | sort | uniq -c | sort -rn \
    | sed 's/^ *\([0-9]*\) /       - (\1회) /'
  printf '%s' "$errs"    | grep -v '^$' | sort -u | sed 's/^/       세션 실패 /'
  printf '%s' "$warns"   | grep -v '^$' | sort -u | sed 's/^/       경고 /'
  printf '%s' "$keeps"   | grep -v '^$' | sed 's/^/       기록: /'
  printf 'STATUS:%s\n' "$st"
}

PASS=0; FAIL=0; ERR=0; FAILED=(); ERRED=()
OUTD=$(mktemp -d)
trap 'rm -rf "$OUTD"' EXIT

# 케이스끼리는 샌드박스가 따로라 같이 돌려도 안 부딪힌다.
# 다만 동시에 너무 많이 띄우면 세션이 느려져 제한 시간에 걸린다.
if [ "$JOBS" -le 1 ]; then
  for name in "${WANT[@]}"; do run_case "$name" >"$OUTD/$name.out" 2>&1; done
else
  for name in "${WANT[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
    run_case "$name" >"$OUTD/$name.out" 2>&1 &
  done
  wait
fi

# 낸 순서대로 보여준다. 동시에 돌아도 출력은 섞이지 않는다.
for name in "${WANT[@]}"; do
  [ -f "$OUTD/$name.out" ] || continue
  sed '/^STATUS:/d' "$OUTD/$name.out"
  case "$(sed -n 's/^STATUS://p' "$OUTD/$name.out" | tail -1)" in
    pass) PASS=$((PASS+1)) ;;
    fail) FAIL=$((FAIL+1)); FAILED+=("$name") ;;
    err)  ERR=$((ERR+1));  ERRED+=("$name") ;;
  esac
done

echo
if [ "$REPS" -eq 1 ]; then
  echo "$((PASS+FAIL))개 중 ${PASS}개 통과, ${FAIL}개 실패"
else
  echo "$((PASS+FAIL))개 중 ${PASS}개가 전부 통과, ${FAIL}개는 한 번이라도 실패"
fi
if [ "$ERR" -gt 0 ]; then
  echo "돌리지 못함: ${ERRED[*]} - 규칙이 아니라 환경 문제입니다. 로그인이 풀렸는지 보세요"
  exit 2
fi
[ "$FAIL" -eq 0 ] || { echo "실패: ${FAILED[*]}"; exit 1; }
exit 0