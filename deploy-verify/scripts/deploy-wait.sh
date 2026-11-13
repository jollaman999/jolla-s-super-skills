#!/usr/bin/env bash
# 7단계: 원격 컨테이너가 healthy 가 될 때까지 상한을 두고 대기.
# usage: deploy-wait.sh <host> <container> [max_sec] [ssh_opts...]
# exit : 0=healthy 1=타임아웃(로그 출력) 2=접속 실패 또는 도구 없음
#
# 이식성: timeout(1) 이 없는 환경(일부 Git Bash)에서는 내장 워치독으로 상한을 건다.
# 비밀번호(VH_PW)는 sshpass -e 로 환경 변수 SSHPASS 에 실어 넘긴다. 명령 줄에 안 나온다.
set -uo pipefail
H="${1:?host}"; C="${2:?container}"; MAX="${3:-120}"; shift 3 2>/dev/null || shift $#
IV=5; N=$(( MAX / IV )); [ "$N" -lt 1 ] && N=1
U="${VH_USER:-root}"; P="${VH_PORT:-22}"

have() { command -v "$1" >/dev/null 2>&1; }

# 도구가 없어서 못 붙는 것을 배포 실패로 보고하면 안 된다. 접속 실패(2)로 갈라 낸다.
have ssh || { echo "UNREACHABLE $H : ssh 가 없습니다. Windows 는 Git for Windows 를 설치하고 Git Bash 에서 실행하세요"; exit 2; }
if [ -n "${VH_PW:-}" ] && ! have sshpass; then
  echo "UNREACHABLE $H : 비밀번호 인증에는 sshpass 가 필요한데 없습니다. Git Bash 에는 기본 포함되지 않습니다 -> SSH 키(VH_KEY)를 쓰거나 winget install -e --id xhcoding.sshpass-win32 로 까세요"
  exit 2
fi

# Windows(Git Bash) 의 winget 판 sshpass-win32 는 ConPTY 로 ssh 를 띄워 Git Bash 의 ssh(MSYS)와는 멈춘다.
# 그 판이면 Windows OpenSSH 를 쓴다. 가르는 기준과 근거는 verify-impl/scripts/ssh-run.sh 와 같다 (-V 를 모르면 sshpass-win32).
SSH_BIN=ssh; KH=/dev/null; PTY=""; NOCONV=""
if [ -n "${VH_PW:-}" ]; then
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*)
      case "$(sshpass -V 2>/dev/null)" in
        "sshpass "*) ;;
        *) PTY=1
           WINSSH="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}" 2>/dev/null || echo /c/Windows)/System32/OpenSSH/ssh.exe"
           if [ -f "$WINSSH" ]; then SSH_BIN=$(cygpath -w "$WINSSH"); KH=NUL; NOCONV=1
           else echo "[주의] sshpass-win32 는 Git Bash 의 ssh 와 물리지 않아 멈춥니다. Windows OpenSSH($WINSSH)가 없어 PATH 의 ssh 를 씁니다 -> 선택적 기능에서 OpenSSH 클라이언트를 켜거나 SSH 키(VH_KEY)를 쓰세요"
           fi ;;
      esac ;;
  esac
fi

# ConPTY 가 붙이는 제어 문자와 CR, 앞쪽 빈 줄을 걷는다. sshpass-win32 일 때만 쓴다
pty_clean() {
  local e b; e=$(printf '\033'); b=$(printf '\007')
  sed -e "s|${e}\[[0-9;?]*[ -/]*[@-~]||g" -e "s|${e}\][^${b}]*${b}||g" -e "s|${e}[=>]||g" | tr -d '\r' | awk 'NF{s=1} s'
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
  [ "$rc" -ge 128 ] && rc=124
  return "$rc"
}

SSHO=(-n -o StrictHostKeyChecking=no -o "UserKnownHostsFile=$KH" -o LogLevel=ERROR -o ConnectTimeout=10 -p "$P")
# 비밀번호 접속에서 에이전트·기본 키를 먼저 내밀면 MaxAuthTries 에 걸려 끊긴다
PWOPTS=(-o PubkeyAuthentication=no -o "PreferredAuthentications=password,keyboard-interactive")
run(){ if [ -n "${VH_PW:-}" ]; then
         ( export SSHPASS="$VH_PW"
           [ -n "$NOCONV" ] && export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
           run_to 30 sshpass -e "$SSH_BIN" "${SSHO[@]}" "${PWOPTS[@]}" "$U@$H" "$1" 2>&1 ) |
           if [ -n "$PTY" ]; then pty_clean; else cat; fi
       else run_to 30 ssh "${SSHO[@]}" ${VH_KEY:+-i "$VH_KEY"} "$U@$H" "$1" 2>&1; fi; }

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
