#!/usr/bin/env bash
# F 노드 전처리: 대상 도달성 확인. 도달 불가면 exit 1 -> 해당 항목은 unknown 처리.
# usage: probe.sh <base_url> [path]
set -uo pipefail
BASE="${1:?usage: probe.sh <base_url> [path]}"
PATH_="${2:-/}"
URL="${BASE%/}${PATH_}"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --connect-timeout 5 "$URL" 2>/tmp/probe.err)
RC=$?
if [ $RC -ne 0 ]; then
  echo "UNREACHABLE $URL : $(head -c 200 /tmp/probe.err)"
  exit 1
fi
echo "REACHABLE $URL http=$CODE"
# 000 은 curl 실패, 5xx 는 살아있지만 고장 -> 둘 다 도달성은 있음/없음 구분해서 알림
[ "$CODE" = "000" ] && exit 1
exit 0
