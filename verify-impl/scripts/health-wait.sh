#!/usr/bin/env bash
# L·F 노드: 헬스가 통과할 때까지 상한을 두고 폴링한다. 무한 대기 금지.
# usage: health-wait.sh <url|docker:CONTAINER> [max_sec] [interval]
# exit : 0=healthy 1=타임아웃 2=인자오류
set -uo pipefail
T="${1:?usage: health-wait.sh <url|docker:NAME> [max_sec] [interval]}"
MAX="${2:-60}"; IV="${3:-3}"
N=$(( MAX / IV )); [ "$N" -lt 1 ] && N=1

for i in $(seq 1 "$N"); do
  if [[ "$T" == docker:* ]]; then
    C="${T#docker:}"
    S=$(docker inspect "$C" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null)
    echo "[$i/$N] $C = ${S:-not-found}"
    case "$S" in healthy|running) echo "OK $C=$S"; exit 0 ;; esac
  else
    CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$T" 2>/dev/null)
    echo "[$i/$N] $T = ${CODE:-000}"
    case "$CODE" in 2*|3*) echo "OK $T=$CODE"; exit 0 ;; esac
  fi
  sleep "$IV"
done
echo "TIMEOUT: ${MAX}s 안에 정상화되지 않음 -> 로그를 먼저 확인할 것"
exit 1
