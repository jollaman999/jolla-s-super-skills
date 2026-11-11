#!/usr/bin/env bash
# doc-write 가 쓰는 why-hwp 실행 파일을 GitHub 릴리즈에서 받아 doc-write/bin/ 에 둔다.
# hwp/hwpx 읽기·변환과 SVG -> PNG 에 쓴다. 실행 파일은 repo 에 넣지 않고 설치 때 받는다.
#
# usage: fetch-why-hwp.sh [--check | --which] [--force] [--dest DIR]
#   (옵션 없음) : 쓸 수 있는 why-hwp 가 없으면 받는다
#   --check     : 무엇을 쓸지와 그 버전만 보고 끝낸다. 받지 않는다
#   --which     : 쓸 실행 파일 경로 한 줄만 낸다. 없으면 아무것도 안 내고 1. 받지 않는다
#   --force     : bin/ 에 이미 있어도 다시 받는다 (WHY_HWP_BIN·PATH 의 것은 그대로 쓴다)
#   --dest DIR  : 받을 곳. 기본은 이 스크립트 옆의 ../bin
#
# 찾는 순서 (앞에서 찾으면 받지 않는다)
#   1) WHY_HWP_BIN   직접 받은 실행 파일 경로. 폐쇄망용
#   2) PATH 의 why-hwp
#   3) <dest>/why-hwp[.exe]   이 스크립트가 받아 둔 것
#
# 환경 변수
#   WHY_HWP_BIN      위 1)
#   WHY_HWP_VERSION  받을 버전 (예 v0.2.0). 없으면 최신 릴리즈
#   WHY_HWP_BASE_URL 릴리즈 파일을 받을 곳. 기본 https://github.com/jollaman999/why-hwp/releases/download
#                    사내 미러나 file:// 로 바꿀 때 쓴다. 최신 버전은 못 찾으니 WHY_HWP_VERSION 을 같이 준다
#
# exit: 0=쓸 수 있는 why-hwp 가 있음  1=없음 (릴리즈 없음, 네트워크, 검증 실패, 버전 낮음)  2=사용법 오류
set -uo pipefail

REPO_SLUG="jollaman999/why-hwp"
# skill 문서가 기대하는 명령이 들어간 첫 버전. 이보다 낮으면 쓰지 않는다.
MIN_VERSION="v0.2.0"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$(dirname "$HERE")/bin"
MODE=fetch; FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check)   MODE=check ;;
    --which)   MODE=which ;;
    --force)   FORCE=1 ;;
    --dest)    shift; DEST="${1:-}"; [ -n "$DEST" ] || { sed -n '5,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; } ;;
    --dest=*)  DEST="${1#--dest=}" ;;
    -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "모르는 옵션: $1" >&2; sed -n '5,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
  shift
done

say(){ [ "$MODE" = which ] || printf '%s\n' "$*"; }

# --- 플랫폼 ---
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows; EXT=.exe ;;
  Linux*)               OS=linux;   EXT="" ;;
  Darwin*)              OS=darwin;  EXT="" ;;
  *)                    OS=""; EXT="" ;;
esac
case "$(uname -m 2>/dev/null)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *)             ARCH="" ;;
esac
# Windows ARM 의 Git Bash 는 x86_64 로 에뮬레이션되어 uname 이 x86_64 를 낸다. OS 가 알려주는 값을 본다.
if [ "$OS" = windows ]; then
  case "${PROCESSOR_ARCHITEW6432:-${PROCESSOR_ARCHITECTURE:-}}" in
    ARM64|arm64) ARCH=arm64 ;;
  esac
fi
LOCAL="$DEST/why-hwp$EXT"

# --- 버전 ---
# why-hwp version 은 "why-hwp v0.1.0" 처럼 낸다. 개발 빌드는 커밋 해시가 온다.
bin_version() { # <실행 파일>
  "$1" version 2>/dev/null | awk 'NR==1{print $NF}'
}

# 0=최소 이상  1=낮음  2=버전을 읽을 수 없음 (개발 빌드 등)
version_ok() { # <버전>
  local v="${1#v}" m="${MIN_VERSION#v}" a b i
  v="${v%%-*}"
  case "$v" in
    ''|*[!0-9.]*) return 2 ;;
  esac
  IFS=. read -r -a a <<< "$v"
  IFS=. read -r -a b <<< "$m"
  for i in 0 1 2; do
    if [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ]; then return 0; fi
    if [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ]; then return 1; fi
  done
  return 0
}

# 쓸 수 있으면 0. 버전이 낮으면 1. 실행이 안 되면 3.
judge() { # <실행 파일> <어디서 찾았나>
  local f="$1" from="$2" ver rc
  ver=$(bin_version "$f")
  if [ -z "$ver" ]; then
    say "  [없음] $from: $f 가 실행되지 않습니다"
    return 3
  fi
  version_ok "$ver"; rc=$?
  case "$rc" in
    0) say "  [ok]   $from: $f ($ver)" ;;
    1) say "  [낮음] $from: $f ($ver). 최소 $MIN_VERSION 이 필요합니다"
       return 1 ;;
    2) say "  [주의] $from: $f ($ver). 릴리즈 버전이 아니라 최소 버전($MIN_VERSION)과 비교하지 못했습니다" ;;
  esac
  [ "$MODE" = which ] && printf '%s\n' "$f"
  return 0
}

# --- 1) WHY_HWP_BIN, 2) PATH ---
# 사용자가 직접 둔 것은 받아서 덮지 않는다. 버전이 낮으면 알리고 멈춘다.
if [ -n "${WHY_HWP_BIN:-}" ]; then
  if [ ! -f "$WHY_HWP_BIN" ]; then
    say "  [없음] WHY_HWP_BIN: $WHY_HWP_BIN 이 없습니다"
    exit 1
  fi
  judge "$WHY_HWP_BIN" WHY_HWP_BIN; rc=$?
  [ "$rc" -eq 0 ] && exit 0
  say "  WHY_HWP_BIN 이 가리키는 파일을 새 버전으로 바꾸거나, 변수를 지우고 다시 실행하세요."
  exit 1
fi
if command -v why-hwp >/dev/null 2>&1; then
  judge "$(command -v why-hwp)" PATH; rc=$?
  [ "$rc" -eq 0 ] && exit 0
  say "  PATH 의 why-hwp 를 새 버전으로 바꾸거나 PATH 에서 빼고 다시 실행하세요."
  exit 1
fi

# --- 3) 받아 둔 것 ---
if [ -f "$LOCAL" ] && [ "$FORCE" -eq 0 ]; then
  judge "$LOCAL" "받아 둔 것"; rc=$?
  [ "$rc" -eq 0 ] && exit 0
  [ "$MODE" = fetch ] || exit 1
  say "  다시 받습니다."
fi

if [ "$MODE" != fetch ]; then
  say "  [없음] why-hwp 를 못 찾았습니다 (WHY_HWP_BIN, PATH, $LOCAL)"
  say "  받기: bash $HERE/fetch-why-hwp.sh"
  exit 1
fi

# --- 받기 ---
if [ -z "$OS" ] || [ -z "$ARCH" ]; then
  say "이 플랫폼용 실행 파일이 없습니다: $(uname -s 2>/dev/null) $(uname -m 2>/dev/null)"
  say "릴리즈는 windows·linux·darwin 의 amd64·arm64 만 냅니다."
  exit 1
fi

DL=""
if command -v curl >/dev/null 2>&1; then DL=curl
elif command -v wget >/dev/null 2>&1; then DL=wget
else
  say "curl 도 wget 도 없어 받을 수 없습니다."
  say "폐쇄망이면 실행 파일을 직접 옮긴 뒤 WHY_HWP_BIN=<경로> 로 지정하거나 PATH 에 두세요."
  exit 1
fi

# 0=받음  4=404 (없음)  5=403 (호출 제한 등)  1=그 밖의 실패
get() { # <URL> <저장할 파일>
  local code out rc
  if [ "$DL" = curl ]; then
    code=$(curl -sSL --connect-timeout 15 --max-time 600 -o "$2" -w '%{http_code}' "$1" 2>/dev/null); rc=$?
    [ "$code" = 404 ] && return 4
    [ "$code" = 403 ] && return 5
    [ "$rc" -eq 0 ] && [ "$code" = 200 ] && return 0
    # file:// 은 HTTP 코드가 없다 (000). 읽혔으면 받은 것이다.
    [ "$rc" -eq 0 ] && [ "${1#file://}" != "$1" ] && return 0
    [ "$rc" -eq 37 ] && return 4
    return 1
  fi
  out=$(wget -S -q --timeout=30 --tries=2 -O "$2" "$1" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && return 0
  printf '%s' "$out" | grep -q 'HTTP/[0-9.]* 404' && return 4
  printf '%s' "$out" | grep -q 'HTTP/[0-9.]* 403' && return 5
  return 1
}

sha256_of() { # <파일>
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}

TMP_API=$(mktemp) || { say "임시 파일을 만들 수 없습니다"; exit 1; }
TMP_SUM=$(mktemp) || { rm -f "$TMP_API"; say "임시 파일을 만들 수 없습니다"; exit 1; }
# 실행 파일은 옮길 때 같은 디스크여야 해서 받을 곳 안에 둔다. 경로는 받기 직전에 정한다.
TMP_BIN=""
cleanup() { rm -f "$TMP_API" "$TMP_SUM"; [ -z "$TMP_BIN" ] || rm -f "$TMP_BIN"; }
trap cleanup EXIT

RELEASES="https://github.com/$REPO_SLUG/releases"
BASE_URL="${WHY_HWP_BASE_URL:-$RELEASES/download}"
BASE_URL="${BASE_URL%/}"
hint_manual() {
  say "폐쇄망이거나 직접 받은 실행 파일이 있으면 WHY_HWP_BIN=<경로> 로 지정하거나 PATH 에 두세요."
}

TAG="${WHY_HWP_VERSION:-}"
if [ -z "$TAG" ]; then
  get "https://api.github.com/repos/$REPO_SLUG/releases/latest" "$TMP_API"; rc=$?
  case "$rc" in
    0) TAG=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP_API" | head -1) ;;
    4) say "why-hwp 릴리즈가 아직 없습니다: $RELEASES"
       hint_manual
       exit 1 ;;
    5) say "GitHub API 가 요청을 거절했습니다 (403, 호출 제한일 수 있습니다). 잠시 뒤 다시 하거나 WHY_HWP_VERSION=<태그> 로 버전을 정해 주세요."
       exit 1 ;;
    *) say "GitHub 에 닿지 못했습니다 ($DL). 네트워크를 확인하세요."
       hint_manual
       exit 1 ;;
  esac
  if [ -z "$TAG" ]; then
    say "최신 릴리즈의 태그를 읽지 못했습니다: $RELEASES"
    exit 1
  fi
fi

version_ok "$TAG"; rc=$?
if [ "$rc" -eq 1 ]; then
  say "릴리즈 $TAG 는 최소 버전 $MIN_VERSION 보다 낮습니다. 받지 않습니다."
  exit 1
fi

ASSET="why-hwp-$OS-$ARCH$EXT"
BASE="$BASE_URL/$TAG"
say "why-hwp $TAG 를 받습니다 ($ASSET)"

get "$BASE/SHA256SUMS" "$TMP_SUM"; rc=$?
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 4 ]; then say "릴리즈 $TAG 가 없거나 SHA256SUMS 가 없습니다: $BASE/SHA256SUMS"
  else say "SHA256SUMS 를 받지 못했습니다: $BASE/SHA256SUMS"; fi
  hint_manual
  exit 1
fi
# 줄 모양은 "<해시>  이름" 또는 "<해시> *이름" (sha256sum 의 바이너리 표시)
WANT=$(awk -v n="$ASSET" '{f=$2; sub(/^\*/, "", f); if (f == n) {print tolower($1); exit}}' "$TMP_SUM")
if [ -z "$WANT" ]; then
  say "SHA256SUMS 에 $ASSET 줄이 없습니다. 이 플랫폼용 파일이 릴리즈에 없는 것 같습니다."
  exit 1
fi

mkdir -p "$DEST" || { say "받을 곳을 만들 수 없습니다: $DEST"; exit 1; }
TMP_BIN="$DEST/.why-hwp.download.$$"
get "$BASE/$ASSET" "$TMP_BIN"; rc=$?
if [ "$rc" -ne 0 ]; then
  say "실행 파일을 받지 못했습니다: $BASE/$ASSET"
  exit 1
fi

GOT=$(sha256_of "$TMP_BIN" | tr 'A-F' 'a-f') || GOT=""
if [ -z "$GOT" ]; then
  say "sha256sum 도 shasum 도 없어 확인할 수 없습니다. 확인 안 된 파일은 두지 않습니다."
  exit 1
fi
if [ "$GOT" != "$WANT" ]; then
  say "SHA256 이 맞지 않습니다. 받은 파일을 버립니다."
  say "  기대 $WANT"
  say "  받음 $GOT"
  exit 1
fi

chmod +x "$TMP_BIN"
mv -f "$TMP_BIN" "$LOCAL" || { say "옮기지 못했습니다: $LOCAL (실행 중이면 닫고 다시 하세요)"; exit 1; }
say "  SHA256 일치 ($GOT)"
judge "$LOCAL" "받은 것"; rc=$?
[ "$rc" -eq 0 ] && exit 0
exit 1
