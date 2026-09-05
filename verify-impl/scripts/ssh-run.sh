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
#   VH_BYPASS 접속 실패 시 재시도할 인터페이스명. 미설정이면 재시도하지 않는다.
#             VPN 이 default 라우트를 잡아 나가는 공인 IP 가 바뀐 경우에만 의미가 있다.
#             값은 팀장이 사용자 승인을 받아 확정해서 넘긴다 - 스크립트가 고르지 않는다.
#
# usage: ssh-run.sh <id> '<원격명령>'
# exit : 0=성공(=pass 후보) 1=원격 비0 종료(=fail 후보) 2=접속/타임아웃/도구없음(=unknown)
#
# 이식성: 외부 의존은 ssh 와 awk 뿐이다. jq/python 은 쓰지 않는다.
#         예외로 Windows 의 경로 진단에만 powershell 을 쓴다. 없으면 진단만 생략된다.
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
  printf '{"id":"%s","host":"%s","verdict":"%s","rc":%d,"conn":"%s","via":"%s","evidence":%s,"cmd":%s}\n' \
    "$ID" "$HOST" "$1" "$RC" "$DESC" "$VIA" \
    "$(printf '%s' "$SAFE_OUT" | json_str)" "$(printf '%s' "$SAFE_CMD" | json_str)"
}

# --- 사전 점검 ---
# 도구가 없어서 실행 못 하는 것을 fail(=구현이 틀렸다)로 보고하면 안 된다. unknown 이다.
PRE=""
if ! have ssh; then
  PRE="ssh 명령이 없습니다. Windows 는 Git for Windows 를 설치하고 Git Bash 에서 실행하세요"
elif ! have awk; then
  PRE="awk 가 없습니다"
elif [ -n "${VH_PW:-}${VH_JUMPPW:-}" ] && ! have sshpass; then
  PRE="비밀번호 인증에는 sshpass 가 필요한데 없습니다. Git Bash 에는 기본 포함되지 않습니다 -> SSH 키(VH_KEY)를 쓰거나 WSL 에서 실행하세요"
fi
if [ -n "$PRE" ]; then
  RC=127; DESC="preflight"; VIA="direct"
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

ju=""; jh=""; jp=""
if [ -n "${VH_JUMP:-}" ]; then
  ju="${VH_JUMP%%@*}"; jrest="${VH_JUMP#*@}"; jh="${jrest%%:*}"; jp="${jrest##*:}"
  [ "$jp" = "$jrest" ] && jp=22
fi
# 로컬에서 실제로 나가는 대상. 점프를 쓰면 최종 호스트가 아니라 점프가 첫 홉이다.
FIRSTHOP="${jh:-$HOST}"

attempt() {  # 추가 ssh 옵션을 인자로 받아 한 번 실행한다. OUT/RC/DESC 를 세팅
  local extra=("$@")
  if [ -n "${VH_JUMP:-}" ]; then
    local INNER; INNER=$(build_inner)
    if [ -n "${VH_JUMPPW:-}" ]; then
      OUT=$(run_to "$TO" sshpass -p "$VH_JUMPPW" ssh "${OPTS[@]}" ${extra[@]+"${extra[@]}"} -p "$jp" "$ju@$jh" "$INNER" 2>&1); RC=$?
    else
      OUT=$(run_to "$TO" ssh "${OPTS[@]}" ${extra[@]+"${extra[@]}"} -p "$jp" "$ju@$jh" "$INNER" 2>&1); RC=$?
    fi
    DESC="via $ju@$jh:$jp -> $USER_@$HOST:$PORT"
  elif [ -n "${VH_PW:-}" ]; then
    OUT=$(run_to "$TO" sshpass -p "$VH_PW" ssh "${OPTS[@]}" ${extra[@]+"${extra[@]}"} -p "$PORT" "$USER_@$HOST" "$RCMD" 2>&1); RC=$?
    DESC="$USER_@$HOST:$PORT (pw)"
  else
    OUT=$(run_to "$TO" ssh "${OPTS[@]}" ${extra[@]+"${extra[@]}"} ${VH_KEY:+-i "$VH_KEY"} -p "$PORT" "$USER_@$HOST" "$RCMD" 2>&1); RC=$?
    DESC="$USER_@$HOST:$PORT (key)"
  fi
}

# 소스 IP 를 바꿔서 다시 해볼 값이 있는 실패인가.
# "Connection refused" 와 인증 실패는 이미 대상에 도달한 것이라 제외한다.
connect_class() {
  [ "$RC" = 124 ] && return 0
  printf '%s' "$OUT" | grep -qiE 'timed out|no route to host|network is unreachable'
}

# 터널이면 kind, 아니면 빈 값. 이름 규칙(wg*/tun*)은 VPN 클라이언트마다 달라 못 믿는다.
iface_kind() {
  ip -d link show "$1" 2>/dev/null | awk 'NR>=3{
    for (i=1;i<=NF;i++)
      if ($i ~ /^(wireguard|tun|ppp|ipip|ip6tnl|gre|gretap|vti|vti6|sit|xfrm)$/) { print $i; exit }
  }'
}

# Windows 에는 ip(8) 이 없다. PowerShell 로 같은 세 가지를 뽑는다.
#   나가는 인터페이스 / 그것이 터널인가 / 터널 밖 default 후보
# 리눅스의 ip -d link 는 kind 로 확답을 주지만 Windows 에는 그런 것이 없다.
# TAP 계열 VPN 은 이더넷으로 보인다. 그래서 "아니다" 라고 단정하지 않는다.
win_diag() {
  local psbin dst out dev ift desc kind cands
  psbin=""
  for c in powershell.exe powershell pwsh.exe pwsh; do have "$c" && { psbin="$c"; break; }; done
  [ -n "$psbin" ] || return 0
  case "$FIRSTHOP" in
    *[!0-9.]*) dst=$(getent ahostsv4 "$FIRSTHOP" 2>/dev/null | awk 'NR==1{print $1}') ;;
    *)         dst="$FIRSTHOP" ;;
  esac
  [ -z "$dst" ] && return 0

  # 한 번만 부른다. 탭으로 구분해 awk 로 읽는다.
  out=$("$psbin" -NoProfile -Command "
\$ErrorActionPreference='SilentlyContinue'
\$r = Find-NetRoute -RemoteIPAddress '$dst' | Select-Object -First 1
if (-not \$r) { exit 0 }
\$a = Get-NetAdapter -InterfaceIndex \$r.InterfaceIndex
'DEV' + [char]9 + \$r.InterfaceAlias + [char]9 + \$a.InterfaceType + [char]9 + \$a.InterfaceDescription
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | ForEach-Object {
  \$b = Get-NetAdapter -InterfaceIndex \$_.InterfaceIndex
  'DEF' + [char]9 + \$_.InterfaceAlias + [char]9 + \$b.InterfaceType + [char]9 + \$_.RouteMetric + [char]9 + \$b.InterfaceDescription
}" 2>/dev/null | tr -d '\r')
  [ -n "$out" ] || return 0

  dev=$( printf '%s\n' "$out" | awk -F'\t' '$1=="DEV"{print $2; exit}')
  ift=$( printf '%s\n' "$out" | awk -F'\t' '$1=="DEV"{print $3; exit}')
  desc=$(printf '%s\n' "$out" | awk -F'\t' '$1=="DEV"{print $4; exit}')
  [ -n "$dev" ] || return 0
  kind=$(win_kind "$ift" "$desc")

  cands=""
  while IFS="$(printf '\t')" read -r tag a t m d; do
    [ "$tag" = DEF ] || continue
    [ -z "$a" ] && continue
    [ "$a" = "$dev" ] && continue
    [ -n "$(win_kind "$t" "$d")" ] && continue
    cands="$cands $a(metric $m)"
  done <<WINDEFAULTS
$out
WINDEFAULTS

  if [ -n "$kind" ]; then
    printf '[진단] 첫 홉 %s 는 %s(%s)로 나감. 터널 밖 default 후보:%s' \
      "$dst" "$dev" "$kind" "${cands:- 없음 (터널이 유일한 default)}"
  else
    printf '[진단] 첫 홉 %s 는 %s(ifType=%s, %s)로 나감. 터널로 보이지 않지만 Windows 에서는 TAP 계열 VPN 도 이더넷으로 보입니다. 다른 default 후보:%s' \
      "$dst" "$dev" "$ift" "$desc" "${cands:- 없음}"
  fi
}

# 터널로 볼 근거가 있으면 그 근거를, 없으면 빈 값. "아니다" 를 뜻하지 않는다.
# ifType 은 IANA 번호다. 23=ppp(WAN Miniport 계열), 131=tunnel 만 본다.
# 53=propVirtual 은 Hyper-V·VMware 가상 어댑터도 달고 나와서 터널로 세면 오탐이다.
win_kind() { # <ifType> <설명>
  case "$1" in 23|131) printf 'ifType=%s' "$1"; return 0 ;; esac
  case "$2" in
    *WireGuard*|*Wintun*|*TAP-Windows*|*TAP-Win32*|*OpenVPN*|*AnyConnect*|\
    *WAN\ Miniport*|*Tailscale*|*ZeroTier*|*NordLynx*|*Proton*|*Mullvad*)
      printf '설명=%s' "$2" ;;
  esac
}

# 접속 실패의 원인 판단에 필요한 로컬 라우팅 상태. 패킷을 내보내지 않는다.
# ip(8) 가 없으면 Windows 쪽으로 넘긴다. 둘 다 없으면 조용히 생략한다.
net_diag() {
  have ip || { win_diag; return 0; }
  local dst dev kind cands d m
  case "$FIRSTHOP" in
    *[!0-9.]*) dst=$(getent ahostsv4 "$FIRSTHOP" 2>/dev/null | awk 'NR==1{print $1}') ;;
    *)         dst="$FIRSTHOP" ;;
  esac
  [ -z "$dst" ] && return 0
  dev=$(ip route get "$dst" 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -z "$dev" ] && return 0
  kind=$(iface_kind "$dev")

  if [ -z "$kind" ]; then
    printf '[진단] 첫 홉 %s 는 %s 로 나감 (터널 아님). 소스 IP 문제가 아닐 수 있음' "$dst" "$dev"
    return 0
  fi

  # 후보는 default 라우트 목록에서만 뽑는다. "라우트가 있는 인터페이스" 로 뽑으면
  # ip route get <dst> oif <any> 가 docker0/virbr0 에도 답을 주기 때문에 다 걸린다.
  cands=""
  while read -r d m; do
    [ -z "$d" ] && continue
    [ "$d" = "$dev" ] && continue
    [ -n "$(iface_kind "$d")" ] && continue
    cands="$cands $d(metric $m)"
  done <<DEFAULTS
$(ip -4 route show default 2>/dev/null | awk '{d="";m="0"; for(i=1;i<=NF;i++){if($i=="dev")d=$(i+1); if($i=="metric")m=$(i+1)} if(d!="")print d, m}')
DEFAULTS

  printf '[진단] 첫 홉 %s 는 %s(kind=%s)로 나감. 터널 밖 default 후보:%s' \
    "$dst" "$dev" "$kind" "${cands:- 없음 (터널이 유일한 default)}"
}

# timeout 은 출력이 비어 있다. 그때 앞에 빈 줄이 붙지 않게 한다.
append_line() { if [ -z "$1" ]; then printf '%s' "$2"; else printf '%s\n%s' "$1" "$2"; fi; }

VIA="direct"
attempt

# 우회는 사용자가 승인해 VH_BYPASS 를 넘겼을 때만 한다. 스크립트가 인터페이스를 고르지 않는다.
# 승인받은 것은 "이 경로로 나가는 나" 지 "다른 공인 IP 로 나가는 나" 가 아니다.
BYPASS_NOTE=""
if [ -n "${VH_BYPASS:-}" ] && connect_class; then
  FIRST_OUT="$OUT"
  attempt -o "BindInterface=$VH_BYPASS"
  if connect_class; then
    BYPASS_NOTE="[우회] $VH_BYPASS 로 재시도했으나 역시 접속 실패"
    OUT=$(append_line "$FIRST_OUT" "[우회 재시도 $VH_BYPASS] $OUT")
  else
    VIA="bypass:$VH_BYPASS"
    BYPASS_NOTE="[우회] 기본 경로 실패 후 $VH_BYPASS 로 재시도해 접속됨. 나가는 공인 IP 가 기본 경로와 다르다"
  fi
fi

# 접속 실패로 끝났으면 진단을 붙인다. 우회 기능을 안 쓰더라도 이건 항상 남는다.
if connect_class; then
  DIAG=$(net_diag)
  [ -z "${VH_BYPASS:-}" ] && DIAG="$DIAG. 우회 미시도 (VH_BYPASS 미설정)"
  OUT=$(append_line "$OUT" "$DIAG")
fi
[ -n "$BYPASS_NOTE" ] && OUT=$(append_line "$OUT" "$BYPASS_NOTE")

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
