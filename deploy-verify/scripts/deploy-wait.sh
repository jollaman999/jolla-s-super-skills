#!/usr/bin/env bash
# 7단계: 원격 컨테이너가 healthy 가 될 때까지 상한을 두고 대기.
# usage: deploy-wait.sh <host> <container> [max_sec] [ssh_opts...]
# exit : 0=healthy 1=타임아웃(로그 출력) 2=접속 실패
set -uo pipefail
H="${1:?host}"; C="${2:?container}"; MAX="${3:-120}"; shift 3 2>/dev/null || shift $#
IV=5; N=$(( MAX / IV )); [ "$N" -lt 1 ] && N=1
U="${VH_USER:-root}"; P="${VH_PORT:-22}"
SSH=(ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -p "$P")
run(){ if [ -n "${VH_PW:-}" ]; then timeout 30 sshpass -p "$VH_PW" "${SSH[@]}" "$U@$H" "$1" 2>&1
       else timeout 30 "${SSH[@]}" ${VH_KEY:+-i "$VH_KEY"} "$U@$H" "$1" 2>&1; fi; }

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
