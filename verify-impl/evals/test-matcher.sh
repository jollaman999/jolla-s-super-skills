#!/usr/bin/env bash
# run.sh 의 판별기만 따로 시험한다. 세션을 안 띄우므로 즉시 끝난다.
# 시험 대상: 금지명령 판별(cmd_regex), 샌드박스 탈출 판별(outside_sandbox),
#            기록에서 고친 파일 뽑기(edited_paths), 마지막 답변 뽑기(final_text)
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

echo "$((PASS+FAIL))개 중 ${PASS}개 통과, ${FAIL}개 실패"
[ "$FAIL" -eq 0 ]
