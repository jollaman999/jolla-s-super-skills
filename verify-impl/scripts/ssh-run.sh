#!/usr/bin/env bash
# F 노드: 원격 명령을 실행하고 결과를 JSON으로 반환한다.
# timeout / StrictHostKeyChecking / 점프호스트 / 시크릿 마스킹이 내장돼 있다.
#
# env:
#   VH_HOST   (필수) 대상 호스트
#   VH_USER   기본 root
#   VH_PORT   기본 22
#   VH_PW     비밀번호 (sshpass 사용). 미설정이면 키 방식
#   VH_KEY    SSH 키 경로
#   VH_JUMP   점프 호스트 "user@host:port" - 설정 시 2단 접속
#   VH_JUMPPW 점프 호스트 비밀번호
#   VH_TO     timeout 초, 기본 60
#
# usage: ssh-run.sh <id> '<원격명령>'
# exit : 0=성공(=pass 후보) 1=원격 비0 종료(=fail 후보) 2=접속/타임아웃(=unknown)
set -uo pipefail
ID="${1:?usage: ssh-run.sh <id> '<cmd>'}"; RCMD="${2:?remote command}"
HOST="${VH_HOST:?VH_HOST required}"; USER_="${VH_USER:-root}"
PORT="${VH_PORT:-22}"; TO="${VH_TO:-60}"

mask() { sed -E \
  -e "s/(-p|--password)[= ]+[^ ]+/\1 ***/g" \
  -e "s/(Bearer|Basic) +[A-Za-z0-9._~+\/=-]+/\1 ***/g" \
  -e "s/([Pp]assword|PASSWORD|passwd|token|TOKEN|secret|SECRET)([\"']?\s*[:=]\s*[\"']?)[^\"' ,}]+/\1\2***/g" \
  ${VH_PW:+-e "s/$(printf '%s' "${VH_PW}" | sed 's/[][\\.*^$\/&]/\\&/g')/***/g"} \
  ${VH_JUMPPW:+-e "s/$(printf '%s' "${VH_JUMPPW}" | sed 's/[][\\.*^$\/&]/\\&/g')/***/g"}; }

# -n: ssh 가 stdin 을 먹어 호출한 스크립트/루프를 삼키는 것을 막는다 (필수)
OPTS=(-n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

build_inner() {  # 점프 호스트 뒤쪽
  if [ -n "${VH_JUMP:-}" ]; then
    local ju="${VH_JUMP%%@*}" jrest="${VH_JUMP#*@}" jh="${jrest%%:*}" jp="${jrest##*:}"
    [ "$jp" = "$jrest" ] && jp=22
    printf '%s' "ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR ${VH_KEY:+-i $VH_KEY} -p $PORT $USER_@$HOST $(printf '%q' "$RCMD")"
  fi
}

if [ -n "${VH_JUMP:-}" ]; then
  ju="${VH_JUMP%%@*}"; jrest="${VH_JUMP#*@}"; jh="${jrest%%:*}"; jp="${jrest##*:}"
  [ "$jp" = "$jrest" ] && jp=22
  INNER=$(build_inner)
  if [ -n "${VH_JUMPPW:-}" ]; then
    OUT=$(timeout "$TO" sshpass -p "$VH_JUMPPW" ssh "${OPTS[@]}" -p "$jp" "$ju@$jh" "$INNER" 2>&1); RC=$?
  else
    OUT=$(timeout "$TO" ssh "${OPTS[@]}" -p "$jp" "$ju@$jh" "$INNER" 2>&1); RC=$?
  fi
  DESC="via $ju@$jh:$jp -> $USER_@$HOST:$PORT"
elif [ -n "${VH_PW:-}" ]; then
  OUT=$(timeout "$TO" sshpass -p "$VH_PW" ssh "${OPTS[@]}" -p "$PORT" "$USER_@$HOST" "$RCMD" 2>&1); RC=$?
  DESC="$USER_@$HOST:$PORT (pw)"
else
  OUT=$(timeout "$TO" ssh "${OPTS[@]}" ${VH_KEY:+-i "$VH_KEY"} -p "$PORT" "$USER_@$HOST" "$RCMD" 2>&1); RC=$?
  DESC="$USER_@$HOST:$PORT (key)"
fi

SAFE_OUT=$(printf '%s' "$OUT" | head -c 4000 | mask)
SAFE_CMD=$(printf '%s' "$RCMD" | mask)

jq_str() { python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'; }
emit() { printf '{"id":"%s","host":"%s","verdict":"%s","rc":%d,"conn":"%s","evidence":%s,"cmd":%s}\n' \
  "$ID" "$HOST" "$1" "$RC" "$DESC" \
  "$(printf '%s' "$SAFE_OUT" | jq_str)" "$(printf '%s' "$SAFE_CMD" | jq_str)"; }

case $RC in
  0)   emit pass;    exit 0 ;;
  124) emit unknown; exit 2 ;;              # timeout
  255) emit unknown; exit 2 ;;              # ssh 접속 실패
  *)   if printf '%s' "$OUT" | grep -qiE 'permission denied|connection refused|no route to host|could not resolve|host key'; then
         emit unknown; exit 2
       fi
       emit fail; exit 1 ;;
esac
