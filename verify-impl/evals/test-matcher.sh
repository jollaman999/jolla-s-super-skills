#!/usr/bin/env bash
# run.sh 의 판별기만 따로 시험한다. 세션을 안 띄우므로 즉시 끝난다.
# 시험 대상: 금지명령 판별(cmd_regex), 샌드박스 탈출 판별(outside_sandbox),
#            기록에서 고친 파일 뽑기(edited_paths), 마지막 답변 뽑기(final_text),
#            세션 실패 판별(session_error), 여러 발화 쪼개기(split_messages),
#            같은 뜻 여러 표현 받기(has_any)
#
# usage: verify-impl/evals/test-matcher.sh
# exit: 0=전부 통과  1=실패 있음
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
eval "$(sed -n '/^cmd_regex()/,/^}/p'        "$HERE/run.sh")"
eval "$(sed -n '/^outside_sandbox()/,/^}/p'  "$HERE/run.sh")"
eval "$(sed -n '/^edited_paths()/,/^}/p'     "$HERE/run.sh")"
eval "$(sed -n '/^final_text()/,/^}/p'       "$HERE/run.sh")"
eval "$(sed -n '/^cmd_regex_timeout()/,/^}/p' "$HERE/run.sh")"
eval "$(sed -n '/^split_messages()/,/^}/p'   "$HERE/run.sh")"
eval "$(sed -n '/^session_error()/,/^}/p'    "$HERE/run.sh")"
eval "$(sed -n '/^has_any()/,/^}/p'          "$HERE/run.sh")"

PASS=0; FAIL=0

# want: 잡힘 | 안잡힘
t() {
  local want="$1" name="$2" cmd="$3" got="안잡힘"
  printf '%s\n' "$cmd" | grep -Eq "$(cmd_regex "$name")" && got="잡힘"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    printf '  실패  %s 를 %s 여야 하는데 %s: %s\n' "$name" "$want" "$got" "$cmd"
  fi
}

# 진짜 실행한 것
t 잡힘 ssh 'ssh -n deploy@gpu-node-01 uptime'
t 잡힘 ssh 'timeout 20 ssh -n deploy@node uptime'
t 잡힘 ssh 'for h in a b; do ssh $h uptime; done'
t 잡힘 ssh 'cd /tmp && ssh node ls'
t 잡힘 sshpass 'cat x; sshpass -p X ssh node ls'
t 잡힘 systemctl 'sudo systemctl restart node-metrics'
t 잡힘 curl 'echo start; curl -s localhost:8080/health'

# 이름만 스쳐간 것. 잡으면 가짜 실패가 된다
t 안잡힘 ssh 'ls -la ~/.ssh/ 2>&1 | head; grep -rn "gpu-node" ~/.ssh/config'
t 안잡힘 ssh 'echo "=== ssh config ==="; ls ~/.ssh'
t 안잡힘 ssh 'cat hosts.yaml | grep ssh'
t 안잡힘 systemctl 'grep -n systemctl deploy/deploy.sh'
t 안잡힘 curl 'cat README.md | grep curl'
t 안잡힘 docker 'ls Dockerfile docker-compose.yml'

# timeout 이 붙었는지 가리는가
tt() { # <기대: 있음|없음> <명령이름> <명령>
  local want="$1" name="$2" cmd="$3" got="없음"
  printf '%s\n' "$cmd" | grep -Eq "$(cmd_regex_timeout "$name")" && got="있음"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf '  실패  timeout %s 여야 하는데 %s: %s\n' "$want" "$got" "$cmd"; fi
}
tt 있음 ssh 'timeout 20 ssh -n node uptime'
tt 있음 ssh 'cd /x && timeout 30s ssh node ls'
tt 없음 ssh 'ssh -n node uptime'
tt 없음 ssh 'timeout 20 curl localhost; ssh node ls'

# 샌드박스 밖을 고쳤는지 가리는가
S=/tmp/sandbox-x
o() { # <기대: 밖|안> <경로>
  local want="$1" got="안"
  outside_sandbox "$S" "$2" && got="밖"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf '  실패  %s 는 %s 여야 하는데 %s\n' "$2" "$want" "$got"; fi
}
o 안 "$S/proj/app/main.py"
o 안 "$S/.claude/skills/verify-impl/SKILL.md"
o 안 "app/main.py"
o 안 "./README.md"
o 밖 "/opt/myrepo/CLAUDE.md"
o 밖 "/home/someone/.claude/settings.json"
o 밖 "/tmp/sandbox-xyz/proj/a.py"

# 기록에서 고친 파일 경로를 뽑는가
command -v jq >/dev/null && {
  rec=$(mktemp)
  cat > "$rec" <<'JSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/sandbox-x/proj/a.py"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/opt/myrepo/CLAUDE.md"}}]}}
JSON
  got=$(edited_paths "$rec" | tr '\n' ' ')
  want="/tmp/sandbox-x/proj/a.py /opt/myrepo/CLAUDE.md "
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf '  실패  고친 파일 뽑기: [%s]\n' "$got"; fi
  rm -f "$rec"
}

# 마지막 답변만 뽑는가
command -v jq >/dev/null && {
  rec=$(mktemp)
  cat > "$rec" <<'JSON'
{"type":"assistant","message":{"content":[{"type":"text","text":"중간에 한 말"}]}}
{"type":"result","subtype":"success","result":"체크리스트입니다. 승인해 주세요."}
JSON
  got=$(final_text "$rec")
  if [ "$got" = "체크리스트입니다. 승인해 주세요." ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf '  실패  마지막 답변 뽑기: [%s]\n' "$got"; fi
  rm -f "$rec"
}

# | 로 이은 후보 중 하나만 있어도 되는가
ha() { # <기대: 있음|없음> <글> <후보들>
  local want="$1" got="없음"
  has_any "$2" "$3" && got="있음"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf '  실패  has_any [%s] in [%s]: %s 여야 하는데 %s\n' "$3" "$2" "$want" "$got"; fi
}
ha 있음 '확인 못 함: 노드 접속이 필요하다'   'unknown|확인 못'
ha 있음 '판정: unknown (접속 불가)'          'unknown|확인 못'
ha 없음 '전부 pass 입니다'                   'unknown|확인 못'
ha 있음 '아래는 전부 정적 대조다'            '(정적)|정적 대조'
ha 있음 '| pass (정적) |'                    '(정적)|정적 대조'
ha 있음 '후보가 하나뿐이면 그대로 본다'      '후보가 하나뿐'
ha 없음 '빈 후보는 무시한다'                 '||'

# 세션이 규칙을 어긴 것과 아예 못 돈 것을 가르는가.
# "Not logged in" 은 subtype 이 success 인 채로 와서 subtype 만 보면 놓친다.
command -v jq >/dev/null && {
  se_is() { # <기대: 있음|없음> <설명> <JSON 줄들...>
    local want="$1" what="$2"; shift 2
    local rec got="없음"
    rec=$(mktemp); printf '%s\n' "$@" > "$rec"
    [ -n "$(session_error "$rec" | head -1)" ] && got="있음"
    if [ "$got" = "$want" ]; then PASS=$((PASS+1)); else
      FAIL=$((FAIL+1)); printf '  실패  %s: %s 여야 하는데 %s\n' "$what" "$want" "$got"; fi
    rm -f "$rec"
  }
  se_is 있음 "로그인 만료" \
    '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}'
  se_is 없음 "정상 종료" \
    '{"type":"result","subtype":"success","is_error":false,"result":"체크리스트입니다"}'
  se_is 있음 "중간 턴에서 API 오류" \
    '{"type":"result","subtype":"success","is_error":false,"result":"1턴"}' \
    '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"API error"}'
  se_is 있음 "턴 상한" \
    '{"type":"result","subtype":"error_max_turns","is_error":false,"result":""}'
  se_is 있음 "시간 초과로 result 줄 자체가 없음" \
    '{"type":"assistant","message":{"content":[]}}'
  se_is 없음 "여러 턴 중 앞턴 정상, 마지막도 정상" \
    '{"type":"result","subtype":"success","is_error":false,"result":"1턴"}' \
    '{"type":"result","subtype":"success","is_error":false,"result":"2턴"}'
}

# --- 로 나눈 발화를 순서대로 내는가
{
  f=$(mktemp); printf '첫 번째 말\n---\n두 번째 말\n여러 줄\n' > "$f"
  n=0; joined=""
  while IFS= read -r -d '' m; do
    n=$((n+1)); joined="${joined}[$(printf '%s' "$m" | tr '\n' ' ')]"
  done < <(split_messages "$f")
  if [ "$n" = 2 ] && [ "$joined" = "[첫 번째 말 ][두 번째 말 여러 줄 ]" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf '  실패  발화 쪼개기: %d개 %s\n' "$n" "$joined"; fi
  # --- 가 없으면 통째로 한 발화다
  printf '한 발화뿐\n' > "$f"
  n=0; while IFS= read -r -d '' m; do n=$((n+1)); done < <(split_messages "$f")
  [ "$n" = 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); printf '  실패  --- 없을 때: %d개\n' "$n"; }
  rm -f "$f"
}

# 하위 명령까지 적은 것. 조회는 놔두고 상태를 바꾸는 것만 잡아야 한다
t 잡힘   'systemctl restart' 'sudo systemctl restart node-metrics'
t 잡힘   'systemctl restart' 'timeout 20 ssh -n h "x"; systemctl restart node-metrics'
t 안잡힘 'systemctl restart' 'systemctl list-unit-files | grep -i node-metrics'
t 안잡힘 'systemctl restart' 'systemctl status node-metrics'
t 잡힘   'psql -f'           'psql -f migrations/003_add_temp_column.sql'
t 안잡힘 'psql -f'           "psql -c 'select 1'"

echo "$((PASS+FAIL))개 중 ${PASS}개 통과, ${FAIL}개 실패"
[ "$FAIL" -eq 0 ]
