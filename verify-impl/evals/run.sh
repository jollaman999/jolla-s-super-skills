#!/usr/bin/env bash
# 규칙을 지키는지 실제 세션을 돌려서 확인한다.
#
# 케이스마다 임시 폴더를 만들고 이 repo 를 그 안에 설치한 뒤,
# claude -p 로 세션을 한 번 돌리고 무슨 도구를 썼는지 기록에서 확인한다.
#
# usage: verify-impl/evals/run.sh [케이스 ...] [--keep] [--model M] [--turns N] [--timeout S]
#   케이스     : 이름만 준다 (E1 E2). 안 주면 cases/ 안의 전부
#   --keep     : 임시 폴더를 안 지운다. 기록을 직접 볼 때
#   --reps     : 케이스마다 N 번 돌려 통과 횟수를 센다 (기본 1). 세션은 매번 다르게 행동한다
#   --model    : 모델을 고정한다. 안 주면 설정된 기본값
#   --turns    : 세션 최대 턴 수 (기본 30). 모자라면 답변 전에 잘린다
#   --timeout  : 세션 하나의 제한 시간, 초 (기본 420)
#
# exit: 0=전부 통과  1=실패 있음  2=사용법 오류
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"
CASEDIR="$HERE/cases"

KEEP=0; MODEL=""; TURNS=30; LIMIT=420; REPS=1; WANT=()

usage() { sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --keep)    KEEP=1 ;;
    --reps)    shift; REPS="${1:-1}" ;;
    --model)   shift; MODEL="${1:-}" ;;
    --turns)   shift; TURNS="${1:-30}" ;;
    --timeout) shift; LIMIT="${1:-420}" ;;
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

# 한 케이스 실행. 표준출력에 도구 호출 기록(이름<TAB>내용)을 남긴다.
run_session() {
  local prompt="$1" proj="$2" cfg="$3" out="$4"
  local args=(-p "$prompt" --output-format stream-json --verbose
              --max-turns "$TURNS" --dangerously-skip-permissions)
  [ -n "$MODEL" ] && args+=(--model "$MODEL")
  ( cd "$proj" && CLAUDE_CONFIG_DIR="$cfg" timeout "$LIMIT" claude "${args[@]}" ) >"$out" 2>&1
}

# stream-json 에서 도구 호출만 순서대로 뽑는다
tool_calls() {
  jq -r 'select(.type=="assistant") | .message.content[]?
         | select(.type=="tool_use")
         | [.name, ((.input.command // .input.file_path // .input.skill // .input.prompt // "") | tostring | gsub("\n";" "))]
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

# 세션이 어떻게 끝났는지. success 가 아니면 답변이 없다
session_status() {
  jq -r 'select(.type=="result") | (.subtype // "none")' "$1" 2>/dev/null | head -1
}

# 세션이 마지막에 사람에게 낸 답변만 뽑는다
final_text() {
  jq -r 'select(.type=="result") | (.result // empty)' "$1" 2>/dev/null
}

# 파일을 고친 도구에서 대상 경로만 뽑는다
edited_paths() {
  jq -r 'select(.type=="assistant") | .message.content[]?
         | select(.type=="tool_use")
         | select(.name=="Edit" or .name=="Write" or .name=="MultiEdit" or .name=="NotebookEdit")
         | (.input.file_path // .input.notebook_path // empty)' "$1" 2>/dev/null
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

# 케이스를 한 번 돌린다. 결과를 접두사로 구분해 표준출력에 낸다.
#   R:<사유>  실패 사유. 한 줄도 없으면 통과
#   W:<경고>  실패로는 안 세는 것
#   K:<경로>  --keep 일 때 남긴 기록 파일
run_once() { # <케이스이름> <규칙파일> <프롬프트파일>
  local name="$1" rule="$2" txt="$3"
  local sandbox cfg proj out before after status answer calls bash_cmds first early hit bare w c t e line
  local -a why warn needs bans bad ban tos leaks exs need
  sandbox=$(mktemp -d); cfg="$sandbox/.claude"; proj="$sandbox/proj"
  mkdir -p "$cfg" "$proj"
  [ -f "$CREDS" ] && { cp "$CREDS" "$cfg/.credentials.json"; chmod 600 "$cfg/.credentials.json"; }

  CLAUDE_CONFIG_DIR="$cfg" "$REPO/install.sh" --global --yes >"$sandbox/install.log" 2>&1 || {
    printf 'R:설치 오류 (%s)\n' "$sandbox/install.log"; return; }

  # 케이스가 가짜 프로젝트를 요구하면 만들어 둔다
  ( cd "$proj" && git init -q ) 2>/dev/null
  [ -f "$CASEDIR/$name.setup" ] && ( cd "$proj" && bash "$CASEDIR/$name.setup" ) >/dev/null 2>&1

  out="$sandbox/out.json"
  before=$(git -C "$REPO" status --porcelain 2>/dev/null | sort)
  run_session "$(cat "$txt")" "$proj" "$cfg" "$out"
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
  want_skill=$(rule_get "$rule" "skill")
  if [ -n "$want_skill" ]; then
    printf '%s\n' "$calls" | grep -q "^Skill	.*$want_skill" \
      || why+=("skill '$want_skill' 을 안 불렀음")
  fi

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
      why+=("$t 를 썼음: $(printf '%s' "${line#*	}" | cut -c1-60)")
      break
    done <<EOF
$(printf '%s\n' "$calls" | grep "^$t	")
EOF
  done

  # 나오면 안 되는 명령. 실제로 그 명령을 실행했을 때만 잡는다.
  # ls ~/.ssh 나 grep "ssh config" 처럼 이름만 스쳐가는 것은 위반이 아니다.
  bash_cmds=$(printf '%s\n' "$calls" | awk -F'\t' '$1=="Bash"{ $1=""; sub(/^\t/,""); print }')
  IFS=',' read -ra bad <<<"$(rule_get "$rule" "금지명령")"
  for c in "${bad[@]}"; do
    c="$(printf '%s' "$c" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$c" ] || continue
    hit=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      is_exempt "$line" && continue
      hit="$line"; break
    done <<EOF
$(printf '%s\n' "$bash_cmds" | grep -E "$(cmd_regex "$c")")
EOF
    [ -n "$hit" ] && why+=("금지 명령 실행: $(printf '%s' "$hit" | cut -c1-100)")
  done

  # 답변을 보는 검사는 세션이 끝까지 갔을 때만 뜻이 있다.
  # 턴 상한에 걸려 잘린 것을 "규칙을 안 지켰다" 로 읽으면 그게 무음 실패다.
  status=$(session_status "$out")
  answer=$(final_text "$out")
  if [ "$status" != "success" ]; then
    why+=("세션이 답변 전에 끝남: ${status:-없음}. 턴 상한이면 --turns 를 올리세요")
    answer=""
  fi

  # 마지막 답변에 있어야 하는 말 / 있으면 안 되는 말
  [ "$status" = "success" ] && IFS=',' read -ra needs <<<"$(rule_get "$rule" "필수문구")" || needs=()
  for w in "${needs[@]}"; do
    w="$(printf '%s' "$w" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$w" ] || continue
    printf '%s' "$answer" | grep -qF -- "$w" || why+=("응답에 '$w' 가 없음")
  done
  IFS=',' read -ra bans <<<"$(rule_get "$rule" "금지문구")"
  for w in "${bans[@]}"; do
    w="$(printf '%s' "$w" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$w" ] || continue
    printf '%s' "$answer" | grep -qF -- "$w" && why+=("응답에 '$w' 가 있음")
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

  if [ "${#why[@]}" -eq 0 ]; then
    printf '%-4s %-34s 통과\n' "$name" "$desc"
    PASS=$((PASS+1))
  else
    printf '%-4s %-34s 실패\n' "$name" "$desc"
    for w in "${why[@]}"; do printf '       - %s\n' "$w"; done
    FAIL=$((FAIL+1)); FAILED+=("$name")
  fi
  for w in "${warn[@]:-}"; do [ -n "$w" ] && printf '       경고 %s\n' "$w"; done

  if [ "$KEEP" -eq 1 ]; then
    printf '       기록: %s\n' "$out"
  else
    rm -rf "$sandbox"
  fi

  local r
  for r in "${why[@]:-}";  do [ -n "$r" ] && printf 'R:%s\n' "$r"; done
  for r in "${warn[@]:-}"; do [ -n "$r" ] && printf 'W:%s\n' "$r"; done
  if [ "$KEEP" -eq 1 ]; then printf 'K:%s\n' "$out"; else rm -rf "$sandbox"; fi
}

PASS=0; FAIL=0; FAILED=()

for name in "${WANT[@]}"; do
  txt="$CASEDIR/$name.txt"; rule="$CASEDIR/$name.rule"
  [ -f "$txt" ]  || { echo "$name  건너뜀 (프롬프트 파일 없음)"; continue; }
  [ -f "$rule" ] || { echo "$name  건너뜀 (규칙 파일 없음)"; continue; }

  desc=$(rule_get "$rule" "설명")
  ok=0; reasons=""; warns=""; keeps=""
  rep=1
  while [ "$rep" -le "$REPS" ]; do
    result=$(run_once "$name" "$rule" "$txt")
    rs=$(printf '%s\n' "$result" | sed -n 's/^R://p')
    if [ -z "$rs" ]; then ok=$((ok+1)); else reasons="$reasons$rs
"; fi
    warns="$warns$(printf '%s\n' "$result" | sed -n 's/^W://p')
"
    keeps="$keeps$(printf '%s\n' "$result" | sed -n 's/^K://p')
"
    rep=$((rep+1))
  done

  if [ "$REPS" -eq 1 ]; then
    [ "$ok" -eq 1 ] && verdict="통과" || verdict="실패"
  else
    verdict="$ok/$REPS 통과"
  fi
  printf '%-4s %-34s %s\n' "$name" "$desc" "$verdict"

  # 같은 사유가 여러 번 나오면 한 줄로 합친다
  printf '%s' "$reasons" | grep -v '^$' | sort | uniq -c | sort -rn \
    | sed 's/^ *\([0-9]*\) /       - (\1회) /'
  printf '%s' "$warns"   | grep -v '^$' | sort -u | sed 's/^/       경고 /'
  printf '%s' "$keeps"   | grep -v '^$' | sed 's/^/       기록: /'

  if [ "$ok" -eq "$REPS" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$name"); fi
done

echo
if [ "$REPS" -eq 1 ]; then
  echo "$((PASS+FAIL))개 중 ${PASS}개 통과, ${FAIL}개 실패"
else
  echo "$((PASS+FAIL))개 중 ${PASS}개가 ${REPS}회 전부 통과, ${FAIL}개는 한 번이라도 실패"
fi
[ "$FAIL" -eq 0 ] || { echo "실패: ${FAILED[*]}"; exit 1; }
exit 0