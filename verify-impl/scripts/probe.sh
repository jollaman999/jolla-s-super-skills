#!/usr/bin/env bash
# F 노드 전처리: 대상 도달성 확인. 도달 불가면 exit 1 -> 해당 항목은 unknown 처리.
# usage: probe.sh <base_url> [path]
set -uo pipefail
BASE="${1:?usage: probe.sh <base_url> [path]}"
PATH_="${2:-/}"
URL="${BASE%/}${PATH_}"

command -v curl >/dev/null 2>&1 || {
  echo "UNREACHABLE $URL : curl 이 없습니다 (Windows 는 Git for Windows 설치 필요)"; exit 1; }

# /tmp 하드코딩은 동시 실행 시 서로 덮어쓴다. TMPDIR 을 따르는 임시 파일을 쓴다.
ERR=$(mktemp "${TMPDIR:-/tmp}/probe-XXXXXX") || { echo "UNREACHABLE $URL : 임시 파일 생성 실패"; exit 1; }
trap 'rm -f "$ERR"' EXIT

CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --connect-timeout 5 "$URL" 2>"$ERR")
RC=$?
if [ $RC -ne 0 ]; then
  echo "UNREACHABLE $URL : $(head -c 200 "$ERR")"
  exit 1
fi
echo "REACHABLE $URL http=$CODE"
# 000 은 curl 실패, 5xx 는 살아있지만 고장 -> 둘 다 도달성은 있음/없음 구분해서 알림
[ "$CODE" = "000" ] && exit 1
exit 0
