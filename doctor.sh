#!/usr/bin/env bash
# 이 repo 가 이 환경에서 돌 수 있는지 먼저 본다. 아무것도 바꾸지 않는다.
#
# usage: ./doctor.sh
# exit : 0=필수 항목 전부 있음  1=필수 항목이 빠짐
#
# Windows 에서 "왜 안 되지" 를 검증 도중에 알게 되는 것을 막기 위한 스크립트다.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FAIL=0; WARN=0

ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [주의] %s\n' "$*"; WARN=$((WARN+1)); }
bad()  { printf '  [없음] %s\n' "$*"; FAIL=$((FAIL+1)); }

have() { command -v "$1" >/dev/null 2>&1; }

# 있다는 것과 도는 것은 다르다. PATH 에 스텁이 놓여 있는 경우가 실제로 있다.
runs() { # <명령> - 실제로 실행되는지
  case "$1" in
    sed)  printf 'x' | sed 's/x/y/' >/dev/null 2>&1 ;;
    grep) printf 'x\n' | grep -q x 2>/dev/null ;;
    awk)  printf 'x\n' | awk '{print}' >/dev/null 2>&1 ;;
    find) find . -maxdepth 0 >/dev/null 2>&1 ;;
    ssh)  ssh -V >/dev/null 2>&1 ;;
    sshpass) sshpass -V >/dev/null 2>&1 ;;
    *)    "$1" --version >/dev/null 2>&1 ;;
  esac
}
usable() { have "$1" && runs "$1"; }

OS=$(uname -s 2>/dev/null || echo unknown)
case "$OS" in
  MINGW*|MSYS*) ENVNAME="Windows (Git Bash)" ;;
  CYGWIN*)      ENVNAME="Windows (Cygwin)" ;;
  Linux*)       if grep -qi microsoft /proc/version 2>/dev/null; then ENVNAME="WSL"; else ENVNAME="Linux"; fi ;;
  Darwin*)      ENVNAME="macOS" ;;
  *)            ENVNAME="$OS" ;;
esac

echo "환경: $ENVNAME  ($OS)"
echo "bash: ${BASH_VERSION:-?}"
echo "repo: $REPO"
echo

echo "[필수]"
for c in bash awk sed grep find git; do
  if   usable "$c"; then ok "$c"
  elif have "$c";   then bad "$c - PATH 에 있지만 실행되지 않습니다 ($(command -v "$c"))"
  else                   bad "$c"
  fi
done

echo
echo "[검증에 필요]"
usable ssh  && ok "ssh   ($(command -v ssh))"  || bad "ssh   - Windows 는 Git for Windows 설치 필요"
usable curl && ok "curl  ($(command -v curl))" || bad "curl  - Windows 는 Git for Windows 또는 내장 curl 필요"
if usable timeout || usable gtimeout; then ok "timeout"; else warn "timeout 없음 - 스크립트 내장 워치독으로 대신합니다"; fi
if usable sshpass; then ok "sshpass (비밀번호 SSH 가능)"
else warn "sshpass 없음 - 비밀번호 SSH 를 못 씁니다. SSH 키(VH_KEY)를 쓰세요"; fi
if usable docker; then ok "docker"; else warn "docker 없음 - 컨테이너 헬스 체크를 못 합니다"; fi

# Git Bash 에서 Windows 내장 OpenSSH 가 먼저 잡히면 /dev/null 같은 POSIX 경로가 안 넘어간다
case "$OS" in MINGW*|MSYS*|CYGWIN*)
  SSHBIN=$(command -v ssh 2>/dev/null || echo "")
  case "$SSHBIN" in
    /c/Windows/*|/C/Windows/*) warn "ssh 가 Windows 내장 OpenSSH 입니다 ($SSHBIN). Git Bash 의 /usr/bin/ssh 가 먼저 오게 PATH 를 조정하세요" ;;
  esac ;;
esac

echo
echo "[해시·JSON]"
H=""
for h in md5sum sha1sum shasum cksum; do
  have "$h" && printf 'x' | "$h" >/dev/null 2>&1 && { H="$h"; break; }
done
[ -n "$H" ] && ok "해시 도구: $H (snapshot.sh 용)" || bad "md5sum/sha1sum/shasum/cksum 이 전부 없거나 안 돕니다"
PY=""
for c in python3 python py; do
  have "$c" && "$c" -c 'import sys' >/dev/null 2>&1 && { PY="$c"; break; }
done
[ -n "$PY" ] && ok "python: $PY (동시 세션의 최근 편집 목록 표시에만 씁니다)" \
             || warn "python 없음 - 세션 감지는 되지만 최근 편집 목록은 안 나옵니다"

echo
echo "[심볼릭 링크]"
case "$OS" in MINGW*|MSYS*|CYGWIN*) export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict" ;; esac
T="${TMPDIR:-/tmp}/jolla-doctor-link.$$"
rm -rf "$T" 2>/dev/null
if ln -s "$REPO/install.sh" "$T" 2>/dev/null && [ -L "$T" ]; then
  ok "심볼릭 링크 생성 가능 - install.sh 가 링크로 설치합니다"
else
  case "$OS" in
    MINGW*|MSYS*|CYGWIN*)
      warn "심볼릭 링크를 못 만듭니다. 설정 > 개인 정보 및 보안 > 개발자용 > 개발자 모드 를 켜고 Git Bash 를 다시 여세요"
      echo "         켜지 않으면 install.sh 가 복사 설치를 제안합니다 (git pull 후 재실행 필요)" ;;
    *)
      warn "심볼릭 링크를 못 만듭니다. install.sh --copy 로 복사 설치하세요" ;;
  esac
fi
rm -rf "$T" 2>/dev/null

echo
echo "[줄바꿈]"
CRLF=0
for f in "$REPO"/install.sh "$REPO"/hooks/pre-commit "$REPO"/shared/scripts/session-guard.sh; do
  [ -f "$f" ] || continue
  if head -1 "$f" | grep -q $'\r'; then CRLF=1; fi
done
if [ "$CRLF" -eq 1 ]; then
  bad "스크립트가 CRLF 로 체크아웃돼 있습니다 (bad interpreter 로 실행이 안 됩니다)"
  echo "         고치기: git -C \"$REPO\" config core.autocrlf false && git -C \"$REPO\" checkout -- ."
else
  ok "LF (.gitattributes 로 고정돼 있습니다)"
fi

echo
echo "[Claude Code 설정]"
[ -d "$CFG" ] && ok "설정 디렉터리: $CFG" || warn "설정 디렉터리가 없습니다: $CFG (Claude Code 를 한 번 실행하면 생깁니다)"
if [ -d "$CFG/projects" ]; then
  ok "세션 기록: $CFG/projects ($(find "$CFG/projects" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -c . ) 개 프로젝트)"
else
  warn "세션 기록 디렉터리가 없습니다 - 동시 세션 감지가 '확인 불가(exit 2)' 로 나옵니다"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "필수 항목 ${FAIL}개가 빠졌습니다. 주의 ${WARN}개."
  exit 1
fi
echo "필수 항목은 전부 있습니다. 주의 ${WARN}개."
exit 0
