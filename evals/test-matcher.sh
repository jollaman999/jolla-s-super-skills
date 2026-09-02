#!/usr/bin/env bash
# run.sh 의 명령 판별기만 따로 시험한다. 세션을 안 띄우므로 즉시 끝난다.
#
# usage: evals/test-matcher.sh
# exit: 0=전부 통과  1=실패 있음
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
eval "$(sed -n '/^cmd_regex()/,/^}/p' "$HERE/run.sh")"

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

echo "$((PASS+FAIL))개 중 ${PASS}개 통과, ${FAIL}개 실패"
[ "$FAIL" -eq 0 ]
