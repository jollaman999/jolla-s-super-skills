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
# exit : 0=성공(=pass 후보) 1=원격 비0 종료(=fail 후보) 2=접속/타임아웃/도구없음(=unknown)
#
# 이식성: 외부 의존은 ssh 와 awk 뿐이다. jq/python 은 쓰지 않는다.
#         timeout(1) 이 없는 환경(일부 Git Bash)에서는 내장 워치독으로 상한을 건다.
set -uo pipefail
ID="${1:?usage: ssh-run.sh <id> '<cmd>'}"; RCMD="${2:?remote command}"
HOST="${VH_HOST:?VH_HOST required}"; USER_="${VH_USER:-root}"
PORT="${VH_PORT:-22}"; TO="${VH_TO:-60}"

have() { command -v "$1" >/dev/null 2>&1; }

mask() { sed -E \
  -e "s/(-p|--password)[= ]+[^ ]+/\1 ***/g" \
  -e "s/(Bearer|Basic) +[A-Za-z0-9._~+\/=-]+/\1 ***/g" \
  -e "s/([Pp]assword|PASSWORD|passwd|token|TOKEN|secret|SECRET)([\"']?\s*[:=]\s*[\"']?)[^\"' ,}]+/\1\2***/g" \
  ${VH_PW:+-e "s/$(printf '%s' "${VH_PW}" | sed 's/[][\\.*^$\/&]/\\&/g')/***/g"} \
  ${VH_JUMPPW:+-e "s/$(printf '%s' "${VH_JUMPPW}" | sed 's/[][\\.*^$\/&]/\\&/g')/***/g"}; }

# JSON 문자열 인코딩. python/jq 없이 awk 만 쓴다 - Windows Git Bash 에는 python3 가 없다.
# 예전에는 python3 가 없으면 값이 빈 문자열이 되어 JSON 이 깨진 채로 나갔다.
json_str() {
  awk '{ gsub(/\\/,"\\\\"); gsub(/"/,"\\\"");
         gsub(/\t/,"\\t"); gsub(/\r/,"\\r");
         gsub(/[\001-\010\013\014\016-\037\177]/,"");
         out = out (NR>1 ? "\\n" : "") $0 }
       END { printf "\"%s\"", out }'
}

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
  # 시그널로 죽은 것은 원격의 판정 실패가 아니다. fail 이 아니라 unknown 쪽으로 보낸다.
  [ "$rc" -ge 128 ] && rc=124
  return "$rc"
}

emit() { # <verdict>
  printf '{"id":"%s","host":"%s","verdict":"%s","rc":%d,"conn":"%s","evidence":%s,"cmd":%s}\n' \
    "$ID" "$HOST" "$1" "$RC" "$DESC" \
    "$(printf '%s' "$SAFE_OUT" | json_str)" "$(printf '%s' "$SAFE_CMD" | json_str)"
}

# --- 사전 점검 ---
# 도구가 없어서 못 도는 것을 fail(=구현이 틀렸다)로 보고하면 안 된다. unknown 이다.
PRE=""
if ! have ssh; then
  PRE="ssh 명령이 없습니다. Windows 는 Git for Windows 를 설치하고 Git Bash 에서 실행하세요"
elif ! have awk; then
  PRE="awk 가 없습니다"
elif [ -n "${VH_PW:-}${VH_JUMPPW:-}" ] && ! have sshpass; then
  PRE="비밀번호 인증에는 sshpass 가 필요한데 없습니다. Git Bash 에는 기본 포함되지 않습니다 -> SSH 키(VH_KEY)를 쓰거나 WSL 에서 실행하세요"
fi
if [ -n "$PRE" ]; then
  RC=127; DESC="preflight"
  SAFE_OUT="$PRE"; SAFE_CMD=$(printf '%s' "$RCMD" | mask)
  emit unknown; exit 2
fi

# -n: ssh 가 stdin 을 먹어 호출한 스크립트/루프를 삼키는 것을 막는다 (필수)
OPTS=(-n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

build_inner() {  # 점프 호스트 뒤쪽
  if [ -n "${VH_JUMP:-}" ]; then
    printf '%s' "ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR ${VH_KEY:+-i $VH_KEY} -p $PORT $USER_@$HOST $(printf '%q' "$RCMD")"
  fi
}

if [ -n "${VH_JUMP:-}" ]; then
  ju="${VH_JUMP%%@*}"; jrest="${VH_JUMP#*@}"; jh="${jrest%%:*}"; jp="${jrest##*:}"
  [ "$jp" = "$jrest" ] && jp=22
  INNER=$(build_inner)
  if [ -n "${VH_JUMPPW:-}" ]; then
    OUT=$(run_to "$TO" sshpass -p "$VH_JUMPPW" ssh "${OPTS[@]}" -p "$jp" "$ju@$jh" "$INNER" 2>&1); RC=$?
  else
    OUT=$(run_to "$TO" ssh "${OPTS[@]}" -p "$jp" "$ju@$jh" "$INNER" 2>&1); RC=$?
  fi
  DESC="via $ju@$jh:$jp -> $USER_@$HOST:$PORT"
elif [ -n "${VH_PW:-}" ]; then
  OUT=$(run_to "$TO" sshpass -p "$VH_PW" ssh "${OPTS[@]}" -p "$PORT" "$USER_@$HOST" "$RCMD" 2>&1); RC=$?
  DESC="$USER_@$HOST:$PORT (pw)"
else
  OUT=$(run_to "$TO" ssh "${OPTS[@]}" ${VH_KEY:+-i "$VH_KEY"} -p "$PORT" "$USER_@$HOST" "$RCMD" 2>&1); RC=$?
  DESC="$USER_@$HOST:$PORT (key)"
fi

SAFE_OUT=$(printf '%s' "$OUT" | head -c 4000 | mask)
SAFE_CMD=$(printf '%s' "$RCMD" | mask)

case $RC in
  0)   emit pass;    exit 0 ;;
  124) emit unknown; exit 2 ;;              # timeout
  127) emit unknown; exit 2 ;;              # 명령/도구 없음 - 구현 실패가 아니다
  255) emit unknown; exit 2 ;;              # ssh 접속 실패
  *)   if printf '%s' "$OUT" | grep -qiE 'permission denied|connection refused|no route to host|could not resolve|host key'; then
         emit unknown; exit 2
       fi
       emit fail; exit 1 ;;
esac
