#!/usr/bin/env bash
# kill-guard.py 의 판정을 시험한다. 진짜 프로세스를 띄워 그 PID 로 묻는다. 세션을 안 띄우므로 몇 초 안에 끝난다.
#
# 띄우는 것:
#   - timeout 120 sleep 100.<무작위>  자식(sleep)을 거느린다. pkill -f 로 찾을 고유 문자열이 명령 줄에 들어간다
#   - sleep 100                        자식이 없다
#   - setsid bash -c 'sleep 100; :'    자식을 거느린 프로세스 그룹
#   - setsid sleep 100                 자식이 없는 프로세스 그룹
# 띄운 것은 끝날 때 띄운 PID·PGID 로만 정리한다. pkill·killall 로 정리하지 않는다 (남의 프로세스가 걸린다).
#
# usage: shared/scripts/test-kill-guard.sh
#   KG=<경로> 를 주면 그 판정기를 시험한다. 판정을 일부러 망가뜨린 사본으로 이 시험이 실패를 잡는지 볼 때 쓴다.
# exit: 0=전부 통과  1=실패 있음
#       2=python 이 없거나 시험할 수 없는 곳. 이때는 프로세스를 하나도 띄우지 않는다
#         (훅을 돌릴 python 이 /proc 를 못 봄, 셸 쪽에 /proc/<pid>/task/<pid>/children 이 없음)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="${KG:-$HERE/kill-guard.py}"
# 이름만 보고 고르지 않는다. Windows 에는 실행하면 rc=49 로 끝나는 Store 가짜 python3 가 PATH 앞에 있을 수 있다.
PY=""
for _c in python3 python py; do
  command -v "$_c" >/dev/null 2>&1 && "$_c" -c 'import sys' >/dev/null 2>&1 && { PY="$_c"; break; }
done
[ -n "$PY" ] || { echo "python 이 없습니다"; exit 2; }
# 셸의 /proc 만 보면 안 된다. Windows Git Bash 에는 MSYS 의 /proc 가 있지만 훅을 돌리는 Windows python 은 못 본다
"$PY" -c 'import os, sys; sys.exit(0 if os.path.isdir("/proc/self") else 1)' 2>/dev/null \
  || { echo "이 환경의 python($PY) 은 /proc 를 못 봐 kill-guard 가 늘 통과합니다. 시험할 것이 없습니다"; exit 2; }
[ -e "/proc/$$/task/$$/children" ] \
  || { echo "/proc/<pid>/task/<pid>/children 이 없어 시험 프로세스의 자식을 확인할 수 없습니다"; exit 2; }

PIDS=(); GROUPS_=()
cleanup() {
  local p
  for p in "${GROUPS_[@]}"; do kill -- "-$p" 2>/dev/null; done
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
}
trap cleanup EXIT

# children <pid>: 직계 자식 pid. 나타날 때까지 최대 5초 기다린다
# /proc 파일은 크기가 0 으로 보여서 [ -s ] 로는 못 본다. 읽어서 비었는지 본다
children() {
  local f="/proc/$1/task/$1/children" n=0 out
  while [ "$n" -lt 50 ]; do
    out=$(cat "$f" 2>/dev/null)
    [ -n "${out// /}" ] && { printf '%s\n' "$out"; return 0; }
    n=$((n+1)); sleep 0.1
  done
  return 1
}
# pgrp <pid>: 프로세스 그룹 번호 (stat 의 5번째 칸. 2번째 칸 comm 에 공백이 있을 수 있어 ) 뒤를 자른다)
pgrp() { sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f3; }

R="$RANDOM$RANDOM"
timeout 120 sleep "100.$R" & T=$!; PIDS+=("$T")
sleep 100 & S=$!; PIDS+=("$S")
setsid bash -c 'sleep 100; :' & G=$!; GROUPS_+=("$G"); PIDS+=("$G")
setsid sleep 100 & G2=$!; GROUPS_+=("$G2"); PIDS+=("$G2")

for p in "$T" "$G"; do
  kids=$(children "$p") || { echo "준비 실패: $p 의 자식이 안 떴습니다"; exit 1; }
  read -ra _k <<<"$kids"; PIDS+=("${_k[@]}")
  [ "$p" = "$T" ] && TC="${_k[0]}"   # timeout 의 자식 sleep
done
for p in "$G" "$G2"; do
  [ "$(pgrp "$p")" = "$p" ] || { echo "준비 실패: setsid 로 띄운 $p 가 그룹 대표가 아닙니다 (pgrp=$(pgrp "$p"))"; exit 1; }
done
_s=$(cat "/proc/$S/task/$S/children" 2>/dev/null)
[ -n "${_s// /}" ] && { echo "준비 실패: $S 에 자식이 있습니다"; exit 1; }

PASS=0; FAIL=0
TMPF=/tmp/w/stop.sh   # 쓰지 않는다. 시험 명령 글자 안에만 들어간다

# chk <ask|allow> <설명> [도구이름]   명령은 stdin 으로 받는다
chk() {
  local want="$1" what="$2" tool="${3:-Bash}" cmd out got
  cmd=$(cat)
  out=$(printf '%s' "$cmd" | "$PY" -c '
import json, sys
print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"command": sys.stdin.read()}}))' "$tool" | "$PY" "$HOOK")
  local rc=$?
  if [ "$rc" -ne 0 ]; then FAIL=$((FAIL+1)); printf '  실패  %s: 종료 코드 %s\n' "$what" "$rc"; return; fi
  if printf '%s' "$out" | grep -q '"permissionDecision": "ask"'; then got=ask; else got=allow; fi
  if [ "$got" = "$want" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); printf '  실패  %s: %s 여야 하는데 %s\n' "$what" "$want" "$got"; fi
}

echo "== 물어야 하는 것 (자식을 거느린 프로세스)"
chk ask "timeout PID 를 kill -KILL" <<CMD
kill -KILL $T
CMD
chk ask "옵션 없는 kill" <<CMD
kill $T
CMD
chk ask "sudo kill -9" <<CMD
sudo kill -9 $T
CMD
chk ask "cd 뒤의 kill -TERM" <<CMD
cd /tmp; kill -TERM $T
CMD
chk ask "timeout 으로 감싼 kill, 리다이렉트 붙음" <<CMD
timeout 5 kill -s KILL $T >/dev/null 2>&1 || true
CMD
chk ask "bash -c 로 넘긴 kill" <<CMD
bash -c 'sleep 1; kill $T'
CMD
chk ask "이 PC 의 셸이 받는 heredoc 안의 kill" <<CMD
bash <<'EOF'
kill $T
EOF
CMD
chk ask "pkill -f 로 timeout 명령 줄의 고유 문자열" <<CMD
pkill -f 'timeout 120 sleep 100.$R'
CMD
chk ask "이름으로 찾는 pkill -x" <<CMD
pkill -x timeout
CMD
chk ask "killall 이름" <<CMD
killall -9 timeout
CMD
chk ask "음수 PGID 로 그룹 kill (setsid 그룹, 구성원이 자식을 거느림)" <<CMD
kill -TERM -- -$G
CMD
chk ask "신호 뒤의 음수 PGID" <<CMD
kill -9 -$G
CMD
chk ask "대상이 여럿이면 하나라도 자식을 거느리면 묻는다" <<CMD
kill $S $T
CMD

echo "== 물어야 하는 것 (같은 명령 안에서 값을 정할 수 있는 변수·pgrep 치환)"
chk ask "숫자를 넣은 변수 (실제로 빠져나간 명령 모양 그대로, 숫자만 시험 PID)" <<CMD
set -e
TO=$T; CH=$TC
kill -STOP \$TO
# 시험 본체가 끝나면 timeout 을 깨워서 run-wrap.sh 가 정상 마무리하도록 하는 감시자 (분리 실행)
setsid nohup bash -c "while kill -0 \$CH 2>/dev/null; do sleep 5; done; kill -CONT \$TO" >/dev/null 2>&1 < /dev/null &
CMD
chk ask "다시 넣으면 마지막 값, \${NAME} 모양" <<CMD
TO=abc; TO=$T; kill -9 "\${TO}"
CMD
chk ask "export 로 넣은 변수" <<CMD
export P=$T && kill "\$P"
CMD
chk ask "kill \$(pgrep -f 고유 문자열)" <<CMD
kill \$(pgrep -f 'timeout 120 sleep 100.$R')
CMD
chk ask "pgrep 치환을 넣은 변수" <<CMD
P=\$(pgrep -f 'timeout 120 sleep 100.$R'); kill -TERM "\$P"
CMD
chk ask "백틱 pgrep" <<CMD
kill \`pgrep -f 'timeout 120 sleep 100.$R'\`
CMD

echo "== 통과시켜야 하는 것"
chk allow "자식 없는 sleep" <<CMD
kill -9 $S
CMD
chk allow "자식 없는 프로세스 그룹" <<CMD
kill -- -$G2
CMD
chk allow "아무것도 안 맞는 pkill -f" <<CMD
pkill -f 'kg_nomatch_${R}_zz'
CMD
chk allow "아무것도 안 맞는 killall" <<CMD
killall kg_nomatch_$R
CMD
chk allow "kill -0 은 신호를 안 보낸다" <<CMD
kill -0 $T && echo alive
CMD
chk allow "kill -s 0 도 신호를 안 보낸다" <<CMD
kill -s 0 $T
CMD
chk allow "kill -l 은 신호 목록" <<'CMD'
kill -l
CMD
chk allow "같은 명령 안에서 값을 넣지 않은 변수" <<'CMD'
kill $PID
CMD
chk allow "pgrep 이 아닌 치환이라 값을 모름" <<'CMD'
kill $(cat /tmp/w/app.pid)
CMD
chk allow "숫자를 넣은 변수지만 자식 없는 sleep" <<CMD
TO=$S; kill \$TO
CMD
chk allow "숫자가 아닌 값을 넣은 변수" <<'CMD'
TO=abc; kill $TO
CMD
chk allow "숫자 뒤에 숫자가 아닌 값을 다시 넣은 변수" <<CMD
TO=$T; TO=abc; kill \$TO
CMD
chk allow "kill 뒤에 넣은 변수는 그 kill 에 안 쓰인다" <<CMD
kill \$TO; TO=$T
CMD
chk allow "echo 로 찍은 NAME=숫자는 대입이 아니다" <<CMD
echo TO=$T; kill \$TO
CMD
chk allow "파이프가 붙은 pgrep 치환" <<CMD
kill \$(pgrep -f 'timeout 120 sleep 100.$R' | head -1)
CMD
chk allow "아무것도 안 맞는 pgrep 치환" <<CMD
kill \$(pgrep -f 'kg_nomatch_${R}_zz')
CMD
chk allow "파일로 쓰는 heredoc 본문은 실행이 아니다" <<CMD
cat > $TMPF <<'EOF'
kill $T
EOF
CMD
chk allow "주석 안의 kill" <<CMD
# 끝나면 kill $T 로 정리
echo ok
CMD
chk allow "echo 로 찍는 문자열" <<CMD
echo "kill $T 하면 안쪽도 끝난다"
CMD
chk allow "명령 자리가 아닌 kill (인자)" <<CMD
man kill; which kill; echo kill $T
CMD
chk allow "ssh 로 넘긴 kill 은 다른 호스트의 PID 다" <<CMD
timeout 10 ssh -n deploy@host.invalid 'kill $T'
CMD
chk allow "이 시험 스크립트(훅의 조상)는 대상에서 뺀다" <<CMD
kill $$
CMD
chk allow "Bash 가 아닌 도구는 안 본다" Monitor <<CMD
kill -KILL $T
CMD

echo "== 깨진 입력"
out=$(printf 'not json' | "$PY" "$HOOK"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  실패  깨진 입력은 아무것도 안 내고 0 으로 끝나야 한다 (rc=$rc)"; fi

echo "== 시험이 띄운 프로세스가 시험 중에 죽지 않았나"
for p in "$T" "$S" "$G" "$G2"; do
  if kill -0 "$p" 2>/dev/null; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  실패  $p 가 시험 중에 사라졌습니다 (판정기가 신호를 보냈거나 일찍 끝났다)"; fi
done

echo "통과 $PASS, 실패 $FAIL"
[ "$FAIL" -eq 0 ]
