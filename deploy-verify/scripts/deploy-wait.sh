#!/usr/bin/env bash
# 7단계: 원격 컨테이너가 healthy 가 될 때까지 상한을 두고 대기.
# usage: deploy-wait.sh <host> <container> [max_sec] [ssh_opts...]
# exit : 0=healthy 1=타임아웃(로그 출력) 2=접속 실패 또는 도구 없음
#
# 이식성: timeout(1) 이 없는 환경(일부 Git Bash)에서는 내장 워치독으로 상한을 건다.
set -uo pipefail
H="${1:?host}"; C="${2:?container}"; MAX="${3:-120}"; shift 3 2>/dev/null || shift $#
IV=5; N=$(( MAX / IV )); [ "$N" -lt 1 ] && N=1
U="${VH_USER:-root}"; P="${VH_PORT:-22}"

have() { command -v "$1" >/dev/null 2>&1; }

# 도구가 없어서 못 붙는 것을 배포 실패로 보고하면 안 된다. 접속 실패(2)로 갈라 낸다.
have ssh || { echo "UNREACHABLE $H : ssh 가 없습니다. Windows 는 Git for Windows 를 설치하고 Git Bash 에서 실행하세요"; exit 2; }
if [ -n "${VH_PW:-}" ] && ! have sshpass; then
  echo "UNREACHABLE $H : 비밀번호 인증에는 sshpass 가 필요한데 없습니다. Git Bash 에는 기본 포함되지 않습니다 -> SSH 키(VH_KEY)를 쓰거나 WSL 에서 실행하세요"
  exit 2
fi

TIMEOUT_BIN=""
for c in timeout gtimeout; do have "$c" && { TIMEOUT_BIN="$c"; break; }; done

# 상한 없는 원격 명령은 금지다. timeout(1) 이 없으면 직접 건다.
run_to() { # <초> <명령...>   rc 124 = 시간초과
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$@"; return $?; fi
  local secs="$1"; shift
  local pid wd rc
  set -m                          # 자식을 별도 프로세스 그룹으로: 손자까지 같이 죽인다
  "$@" & pid=$!
  set +m
  ( sleep "$secs"; kill -TERM -"$pid" 2>/dev/null
    sleep 2;       kill -KILL -"$pid" 2>/dev/null ) >/dev/null 2>&1 & wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  [ "$rc" -ge 128 ] && rc=124
  return "$rc"
}

SSH=(ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -p "$P")
run(){ if [ -n "${VH_PW:-}" ]; then run_to 30 sshpass -p "$VH_PW" "${SSH[@]}" "$U@$H" "$1" 2>&1
       else run_to 30 "${SSH[@]}" ${VH_KEY:+-i "$VH_KEY"} "$U@$H" "$1" 2>&1; fi; }

if ! run 'echo ok' | grep -q ok; then echo "UNREACHABLE $H"; exit 2; fi

for i in $(seq 1 "$N"); do
  S=$(run "docker inspect $C --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}'" | tr -d '\r')
  echo "[$i/$N] $H:$C = ${S:-not-found}"
  case "$S" in healthy|running) echo "OK $H:$C=$S"; exit 0 ;; esac
  sleep "$IV"
done
echo "TIMEOUT ${MAX}s -- 로그:"
run "docker logs --tail 60 --since 5m $C 2>&1" | sed 's/^/    /'
exit 1
