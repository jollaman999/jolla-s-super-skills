#!/usr/bin/env bash
# 이 repo 를 Claude Code 가 읽는 위치에 건다. 클론 위치는 어디든 상관없다.
#
# 설치 범위
#   전역     : ~/.claude       - 모든 프로젝트에 적용된다
#   프로젝트 : <dir>/.claude   - 그 프로젝트에서만 적용된다
#
# usage: install.sh [--global | --project <dir>] [--copy] [--force] [--dry-run] [--uninstall] [--check] [--yes]
#   --global      : 전역 설치. CLAUDE_CONFIG_DIR 가 있으면 그쪽을 쓴다
#   --project DIR : 그 프로젝트 안에만 설치한다 (DIR/.claude)
#   --copy        : 심볼릭 링크 대신 복사한다. 링크를 못 만드는 환경용
#   --force       : 이미 있는 일반 파일/디렉터리를 <이름>.bak.<날짜> 로 옮기고 덮어쓴다
#   --check       : 이 환경에서 실행될 수 있는지만 보고 끝낸다. 아무것도 안 바꾼다
#   --dry-run     : 무엇을 할지만 출력하고 아무것도 안 바꾼다
#   --uninstall   : 이 스크립트가 설치한 것만 지운다 (남의 파일은 안 건드린다)
#   --yes         : 물어보지 않고 기본값(전역·링크)으로 진행한다
#
# 범위를 안 주고 터미널에서 실행하면 물어본다. 파이프나 CI 에서는 전역으로 간다.
#
# exit: 0=정상  1=충돌 또는 링크 실패로 중단  2=사용법 오류
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MANIFEST_NAME=".jolla-skills.manifest"

SCOPE=""; PROJDIR=""; MODE=""
FORCE=0; DRY=0; UNINSTALL=0; YES=0; CHECK=0

usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --global)     SCOPE=global ;;
    --project)    shift; PROJDIR="${1:-}"; [ -n "$PROJDIR" ] || { usage >&2; exit 2; }; SCOPE=project ;;
    --project=*)  PROJDIR="${1#--project=}"; SCOPE=project ;;
    --copy)       MODE=copy ;;
    --force)      FORCE=1 ;;
    --dry-run)    DRY=1 ;;
    --uninstall)  UNINSTALL=1 ;;
    --check)      CHECK=1 ;;
    --yes|-y)     YES=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "모르는 인자: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

STAMP=$(date +%Y%m%d-%H%M%S)
CONFLICT=0
say(){ printf '%s\n' "$*"; }
run(){ [ "$DRY" -eq 1 ] && { say "    (dry-run) $*"; return 0; }; "$@"; }
ask(){ [ -t 0 ] && [ "$YES" -eq 0 ]; }

is_windows() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }

# --- 사전 점검 ---
# 설치 전에 이 환경에서 실행될 수 있는지 본다. 아무것도 바꾸지 않는다.
# Windows 에서 "왜 안 되지" 를 검증 도중에 알게 되는 것을 막기 위한 것이다.
PF_FAIL=0; PF_WARN=0
pf_ok()   { say "  [ok]   $*"; }
pf_warn() { say "  [주의] $*"; PF_WARN=$((PF_WARN+1)); }
pf_bad()  { say "  [없음] $*"; PF_FAIL=$((PF_FAIL+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

# 있다는 것과 실행되는 것은 다르다. PATH 에 스텁이 놓여 있는 경우가 실제로 있다.
runs() { # <명령> - 실제로 실행되는지
  case "$1" in
    sed)     printf 'x' | sed 's/x/y/' >/dev/null 2>&1 ;;
    grep)    printf 'x\n' | grep -q x 2>/dev/null ;;
    awk)     printf 'x\n' | awk '{print}' >/dev/null 2>&1 ;;
    find)    find . -maxdepth 0 >/dev/null 2>&1 ;;
    ssh)     ssh -V >/dev/null 2>&1 ;;
    sshpass) sshpass -V >/dev/null 2>&1 ;;
    ip)      ip -V >/dev/null 2>&1 ;;
    *)       "$1" --version >/dev/null 2>&1 ;;
  esac
}
usable() { have "$1" && runs "$1"; }

preflight() {
  local OS ENVNAME H PY SSHBIN CRLF f c
  OS=$(uname -s 2>/dev/null || echo unknown)
  case "$OS" in
    MINGW*|MSYS*) ENVNAME="Windows (Git Bash)" ;;
    CYGWIN*)      ENVNAME="Windows (Cygwin)" ;;
    Linux*)       if grep -qi microsoft /proc/version 2>/dev/null; then ENVNAME="WSL"; else ENVNAME="Linux"; fi ;;
    Darwin*)      ENVNAME="macOS" ;;
    *)            ENVNAME="$OS" ;;
  esac
  say "환경: $ENVNAME  ($OS)"
  case "$OS" in
    CYGWIN*) pf_warn "Cygwin 은 Claude Code 의 지원 셸이 아닙니다 (Git Bash 또는 PowerShell). Git Bash 를 쓰세요" ;;
  esac
  say "bash: ${BASH_VERSION:-?}"
  say "repo: $REPO"
  say

  say "[필수]"
  for c in bash awk sed grep find git; do
    if   usable "$c"; then pf_ok "$c"
    elif have "$c";   then pf_bad "$c - PATH 에 있지만 실행되지 않습니다 ($(command -v "$c"))"
    else                   pf_bad "$c"
    fi
  done

  say
  say "[검증에 필요]"
  usable ssh  && pf_ok "ssh   ($(command -v ssh))"  || pf_bad "ssh   - Windows 는 Git for Windows 설치 필요"
  usable curl && pf_ok "curl  ($(command -v curl))" || pf_bad "curl  - Windows 는 Git for Windows 또는 내장 curl 필요"
  if usable timeout || usable gtimeout; then pf_ok "timeout"; else pf_warn "timeout 없음 - 스크립트 내장 워치독으로 대신합니다"; fi
  if usable sshpass; then pf_ok "sshpass (비밀번호 SSH 가능)"
  elif is_windows; then
    pf_warn "sshpass 없음 - Windows 는 SSH 키(VH_KEY)가 기본입니다. 비밀번호가 꼭 필요하면:"
    say "         MSYS2   pacman -S sshpass  (Git Bash 에는 pacman 이 없어 MSYS2 를 따로 깔아야 합니다)"
    say "         Cygwin  setup-x86_64.exe 에서 sshpass 선택  (Cygwin 자체는 지원 셸이 아닙니다)"
    say "         winget  winget install xhcoding.sshpass-win32  (Git Bash 의 ssh 와 물리는지는 검증되지 않았습니다)"
  else pf_warn "sshpass 없음 - 비밀번호 SSH 를 못 씁니다. SSH 키(VH_KEY)를 쓰세요"; fi
  if usable ip; then pf_ok "ip (접속 실패 시 VPN egress 진단 가능)"
  else pf_warn "ip 없음 - 접속 실패 시 VPN egress 진단이 생략됩니다. Windows 에는 iproute2 포트가 없습니다"; fi
  if usable docker; then pf_ok "docker"; else pf_warn "docker 없음 - 컨테이너 헬스 체크를 못 합니다"; fi

  # Git Bash 에서 Windows 내장 OpenSSH 가 먼저 잡히면 /dev/null 같은 POSIX 경로가 안 넘어간다
  if is_windows; then
    SSHBIN=$(command -v ssh 2>/dev/null || echo "")
    case "$SSHBIN" in
      /c/Windows/*|/C/Windows/*) pf_warn "ssh 가 Windows 내장 OpenSSH 입니다 ($SSHBIN). Git Bash 의 /usr/bin/ssh 가 먼저 오게 PATH 를 조정하세요" ;;
    esac
  fi

  say
  say "[해시·JSON]"
  H=""
  for c in md5sum sha1sum shasum cksum; do
    have "$c" && printf 'x' | "$c" >/dev/null 2>&1 && { H="$c"; break; }
  done
  [ -n "$H" ] && pf_ok "해시 도구: $H (snapshot.sh 용)" || pf_bad "md5sum/sha1sum/shasum/cksum 이 전부 없거나 실행되지 않습니다"
  PY=""
  for c in python3 python py; do
    have "$c" && "$c" -c 'import sys' >/dev/null 2>&1 && { PY="$c"; break; }
  done
  [ -n "$PY" ] && pf_ok "python: $PY (지난 세션 검색과 최근 편집 목록에 씁니다)" \
               || pf_warn "python 없음 - 세션 감지는 되지만 지난 세션 검색과 최근 편집 목록은 못 씁니다"

  say
  say "[줄바꿈]"
  CRLF=0
  for f in "$REPO"/install.sh "$REPO"/hooks/pre-commit "$REPO"/shared/scripts/session-guard.sh; do
    [ -f "$f" ] || continue
    head -1 "$f" | grep -q $'\r' && CRLF=1
  done
  if [ "$CRLF" -eq 1 ]; then
    pf_bad "스크립트가 CRLF 로 체크아웃돼 있습니다 (bad interpreter 로 실행이 안 됩니다)"
    say "         고치기: git -C \"$REPO\" config core.autocrlf false && git -C \"$REPO\" checkout -- ."
  else
    pf_ok "LF (.gitattributes 로 고정돼 있습니다)"
  fi

  say
  say "[Claude Code 설정]"
  [ -d "$CFG" ] && pf_ok "설정 디렉터리: $CFG" || pf_warn "설정 디렉터리가 없습니다: $CFG (Claude Code 를 한 번 실행하면 생깁니다)"
  if [ -d "$CFG/projects" ]; then
    pf_ok "세션 기록: $CFG/projects ($(find "$CFG/projects" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -c . ) 개 프로젝트)"
  else
    pf_warn "세션 기록 디렉터리가 없습니다 - 동시 세션 감지가 '확인 불가(exit 2)' 로 나옵니다"
  fi
  say
}

# Git Bash 의 ln -s 는 기본 설정에서 링크를 못 만들면 조용히 "복사" 를 한다.
# 복사가 되면 git pull 해도 반영이 안 되는데 사용자는 링크인 줄 안다.
# nativestrict 를 켜면 못 만들 때 실패하므로 우리가 감지할 수 있다.
# Git Bash 는 MSYS 를, Cygwin 은 CYGWIN 을 읽는다. 하나만 세팅하면 다른 쪽에서 no-op 이 된다.
if is_windows; then
  export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict"
  export CYGWIN="${CYGWIN:+$CYGWIN }winsymlinks:nativestrict"
fi

# 링크 대상: <repo 안 경로>  <설치 위치 안 경로>
LINKS=(
  "CLAUDE.md:CLAUDE.md"
  "design-first:skills/design-first"
  "verify-impl:skills/verify-impl"
  "deploy-verify:skills/deploy-verify"
  "release-cut:skills/release-cut"
  "shared:skills/shared"
  "hooks:skills/hooks"
)
for f in "$REPO"/agents/*.md; do
  [ -e "$f" ] && LINKS+=("agents/$(basename "$f"):agents/$(basename "$f")")
done

# --- 설치 위치 결정 ---
choose_scope() {
  say "설치 범위를 고르세요."
  say
  say "  1) 전역      $CFG"
  say "     모든 프로젝트에서 이 규칙과 skill 이 적용됩니다."
  say
  say "  2) 프로젝트  <경로>/.claude"
  say "     그 프로젝트에서만 적용됩니다."
  say "     팀 repo 에 규칙을 같이 두거나, 전역 설정을 건드리기 싫을 때 씁니다."
  say
  printf '선택 [1/2] (기본 1): '
  local a; read -r a || a=""
  case "$a" in
    2) SCOPE=project
       printf '프로젝트 경로 (기본 %s): ' "$PWD"
       local p; read -r p || p=""
       PROJDIR="${p:-$PWD}" ;;
    *) SCOPE=global ;;
  esac
  say
}

# --check 는 아무것도 안 바꾸므로 설치 범위를 물을 이유가 없다.
# 물으면 터미널에서 실행할 때 응답을 기다리며 멈춘다.
if [ -z "$SCOPE" ]; then
  if [ "$CHECK" -eq 0 ] && ask && [ "$UNINSTALL" -eq 0 ]; then choose_scope; else SCOPE=global; fi
fi

if [ "$SCOPE" = project ]; then
  PROJDIR=$(cd "${PROJDIR:-$PWD}" 2>/dev/null && pwd -P) || { echo "경로 없음: $PROJDIR" >&2; exit 2; }
  DEST="$PROJDIR/.claude"
else
  DEST="$CFG"
fi
MANIFEST="$DEST/$MANIFEST_NAME"

# --- 해제 ---
# 기록(manifest)이 있으면 거기 적힌 것만 지운다. 없으면 예전 방식대로 링크만 본다.
if [ "$UNINSTALL" -eq 1 ]; then
  say "해제: $REPO -> $DEST"
  if [ -f "$MANIFEST" ]; then
    m=$(sed -n 's/^mode=//p' "$MANIFEST" | head -1)
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      d="$DEST/$rel"
      if [ "$m" = link ]; then
        if [ -L "$d" ]; then say "  제거   $rel"; run rm -f "$d"
        else say "  건너뜀 $rel   (링크가 아님)"; fi
      else
        # 복사 설치는 비교할 링크가 없다. 설치 기록만 믿고 지우면, 그 사이 사용자가
        # 같은 자리에 자기 것을 둔 경우 그게 사라진다. 아직 내가 놓은 모양인지 본다.
        # 설치 경로($rel)로 원본 경로를 되찾는다. 둘은 이름이 다르다
        # (repo 의 verify-impl -> 설치본의 skills/verify-impl).
        srcrel=""
        for e in "${LINKS[@]}"; do [ "${e##*:}" = "$rel" ] && { srcrel="${e%%:*}"; break; }; done
        if [ ! -e "$d" ]; then say "  건너뜀 $rel   (없음)"
        elif [ -L "$d" ]; then say "  건너뜀 $rel   (복사본이 아니라 링크로 바뀌어 있음)"
        elif [ -z "$srcrel" ]; then say "  건너뜀 $rel   (원본을 못 찾음)"
        elif [ -d "$REPO/$srcrel" ] && [ ! -d "$d" ]; then say "  건너뜀 $rel   (디렉터리였는데 파일로 바뀌어 있음)"
        elif [ -d "$d" ] && [ -d "$REPO/$srcrel" ] && [ ! -e "$d/$(ls "$REPO/$srcrel" 2>/dev/null | head -1)" ]; then
          say "  건너뜀 $rel   (내용이 설치 당시와 다름)"
        else say "  제거   $rel  (복사본)"; run rm -rf "$d"; fi
      fi
    done < <(sed -n 's/^path=//p' "$MANIFEST")
    run rm -f "$MANIFEST"
    # 비게 된 디렉터리만 정리한다. rmdir 은 비지 않은 것은 건드리지 않는다.
    for d in skills agents; do rmdir "$DEST/$d" 2>/dev/null; done
    rmdir "$DEST" 2>/dev/null
  else
    say "  (설치 기록이 없습니다. 이 repo 를 가리키는 링크만 지웁니다)"
    for e in "${LINKS[@]}"; do
      src="$REPO/${e%%:*}"; d="$DEST/${e##*:}"
      if [ -L "$d" ] && [ "$(readlink -f "$d" 2>/dev/null)" = "$(readlink -f "$src" 2>/dev/null)" ]; then
        say "  제거   ${e##*:}"; run rm -f "$d"
      else
        say "  건너뜀 ${e##*:}   (이 repo 가 건 링크가 아님)"
      fi
    done
  fi
  say
  say "각 repo 의 .git/hooks 에 설치한 훅은 그대로 남습니다."
  say "  지우려면: ~/.claude/skills/hooks/install-hooks.sh <repo> --uninstall"
  exit 0
fi

# --- 심볼릭 링크가 되는 곳인지 먼저 본다 ---
symlink_works() { # <dir>
  local d="$1" t="$1/.jolla-linktest.$$"
  mkdir -p "$d" 2>/dev/null || return 1
  rm -rf "$t" 2>/dev/null
  ln -s "$REPO/install.sh" "$t" 2>/dev/null || { rm -rf "$t" 2>/dev/null; return 1; }
  # 링크가 아니라 복사가 됐으면 실패로 본다. 이게 Git Bash 의 기본 동작이다.
  if [ -L "$t" ]; then rm -f "$t"; return 0; fi
  rm -rf "$t" 2>/dev/null; return 1
}

link_failed_notice() {
  say "심볼릭 링크를 만들 수 없습니다: $DEST"
  if is_windows; then
    say "  Windows 에서 심볼릭 링크를 만들려면 개발자 모드 또는 관리자 권한이 필요합니다."
    say "  Win+R 에 ms-settings:developers 를 입력하면 설정 페이지가 바로 열립니다."
    say "  (Windows 11 25H2 부터는 설정 > 시스템 > 고급 아래, 그 전 버전은 개발자용 페이지에 있습니다.)"
    say "  개발자 모드를 켜고 Git Bash 를 다시 연 뒤 이 스크립트를 다시 실행하면 링크로 설치됩니다."
  else
    say "  파일 시스템이 심볼릭 링크를 지원하지 않는 것 같습니다."
  fi
  say
}

# --check 는 점검만 하고 끝낸다. 예전 doctor.sh 가 하던 일이다.
if [ "$CHECK" -eq 1 ]; then
  preflight
  if [ "$PF_FAIL" -gt 0 ]; then
    say "필수 항목 ${PF_FAIL}개가 빠졌습니다. 주의 ${PF_WARN}개."
    exit 1
  fi
  say "필수 항목은 전부 있습니다. 주의 ${PF_WARN}개."
  exit 0
fi

# 설치 전에 점검한다. 필수가 빠진 채로 깔아 두면 검증 도중에 알게 된다.
preflight
if [ "$PF_FAIL" -gt 0 ]; then
  say "필수 항목 ${PF_FAIL}개가 빠졌습니다. 위를 갖춘 뒤 다시 실행하세요."
  exit 1
fi

if [ -z "$MODE" ] && [ "$DRY" -eq 0 ]; then
  if symlink_works "$DEST"; then
    MODE="link"
  else
    link_failed_notice
    if ! ask; then
      say "복사로 설치하려면 --copy 를 붙여 다시 실행하세요."
      exit 1
    fi
    say "  1) 여기서 멈춥니다. 위 안내대로 조치한 뒤 다시 실행하세요 (권장)"
    if [ "$SCOPE" = global ]; then
      say "  2) 전역 대신 프로젝트 안에 복사로 설치합니다"
    else
      say "  2) 이 위치에 복사로 설치합니다"
    fi
    say "     복사는 링크가 아니라서 git pull 해도 자동 반영되지 않습니다."
    say "     갱신하려면 pull 한 뒤 이 스크립트를 다시 돌려야 합니다."
    say
    printf '선택 [1/2] (기본 1): '
    a=""; read -r a || a=""
    case "$a" in
      2) MODE=copy
         if [ "$SCOPE" = global ]; then
           printf '프로젝트 경로 (기본 %s): ' "$PWD"
           p=""; read -r p || p=""
           PROJDIR=$(cd "${p:-$PWD}" 2>/dev/null && pwd -P) || { echo "경로 없음" >&2; exit 2; }
           SCOPE=project; DEST="$PROJDIR/.claude"; MANIFEST="$DEST/$MANIFEST_NAME"
           say "  -> $DEST 에 복사로 설치합니다"
         fi ;;
      *) exit 1 ;;
    esac
    say
  fi
fi
[ -z "$MODE" ] && MODE="link"

# --- 설치 ---
PLACED=()
mine() { # <설치된 경로> <원본> - 이 repo 가 놓은 것인가
  local d="$1" src="$2" rel="${1#$DEST/}"
  # 링크 설치는 링크인지로 판단한다. 사용자가 링크를 지우고 자기 파일을 둔 경우
  # 설치 기록만 믿고 덮어쓰면 그 파일이 사라진다. 그건 충돌로 봐야 한다.
  if [ "$MODE" = link ]; then
    [ -L "$d" ] && [ "$(readlink -f "$d" 2>/dev/null)" = "$(readlink -f "$src" 2>/dev/null)" ] && return 0
    return 1
  fi
  # 복사 설치는 비교할 링크가 없다. 직전에 이 스크립트가 복사한 것만 갱신 대상이다.
  grep -qxF "mode=copy" "$MANIFEST" 2>/dev/null || return 1
  grep -qxF "path=$rel" "$MANIFEST" 2>/dev/null && return 0
  return 1
}

place_one(){ # <repo 상대경로> <설치 상대경로>
  local src="$REPO/$1" dst="$DEST/$2"
  [ -e "$src" ] || { say "  건너뜀 $2   (원본 없음: $1)"; return; }
  run mkdir -p "$(dirname "$dst")"

  if [ -e "$dst" ] || [ -L "$dst" ]; then
    if mine "$dst" "$src"; then
      say "  갱신   $2"
      run rm -rf "$dst"
    elif [ "$FORCE" -eq 1 ]; then
      say "  대체   $2   (기존 것을 $2.bak.$STAMP 로 옮김)"
      run mv "$dst" "$dst.bak.$STAMP"
    else
      say "  충돌   $2   (이 repo 가 놓은 것이 아닌 파일이 이미 있음)"
      CONFLICT=1
      return
    fi
  else
    say "  생성   $2"
  fi

  if [ "$MODE" = link ]; then
    run ln -sfn "$src" "$dst"
    # 링크가 됐는지 확인한다. 복사로 떨어지면 갱신이 안 되는데 모르고 지나간다.
    if [ "$DRY" -eq 0 ] && [ ! -L "$dst" ]; then
      say "  실패   $2   (링크가 아니라 복사가 됐습니다)"
      CONFLICT=1
      return
    fi
  else
    run cp -R "$src" "$dst"
  fi
  PLACED+=("$2")
}

say "설치: $REPO -> $DEST"
say "  범위: $([ "$SCOPE" = project ] && echo "프로젝트 ($PROJDIR)" || echo "전역")"
say "  방식: $([ "$MODE" = copy ] && echo "복사 (git pull 후 재실행 필요)" || echo "심볼릭 링크")"
say

for e in "${LINKS[@]}"; do place_one "${e%%:*}" "${e##*:}"; done

if [ "$CONFLICT" -eq 1 ]; then
  say
  say "일부를 설치하지 못했습니다."
  say "기존 것을 살펴본 뒤, 덮어써도 되면: $0 --force"
  exit 1
fi

if [ "$DRY" -eq 1 ]; then
  say
  say "dry-run 이라 아무것도 바꾸지 않았습니다."
  exit 0
fi

# --- 설치 기록 ---
# --uninstall 이 무엇을 지울지 여기서만 정한다. 이름 규칙으로 추측하지 않는다.
{
  echo "# jolla-s-super-skills 설치 기록. --uninstall 이 이 목록만 지운다."
  echo "mode=$MODE"
  echo "repo=$REPO"
  echo "scope=$SCOPE"
  for p in "${PLACED[@]}"; do echo "path=$p"; done
} > "$MANIFEST"

# --- 확인 ---
say
say "[확인]"
OK=1
for e in "${LINKS[@]}"; do
  d="$DEST/${e##*:}"
  if [ -e "$d" ]; then say "  ok   ${e##*:}"; else say "  실패 ${e##*:}"; OK=0; fi
done

say
if [ "$OK" -eq 1 ]; then
  if [ "$MODE" = link ]; then
    say "완료. 링크라서 이 repo 를 git pull 하면 바로 반영됩니다."
  else
    say "완료. 복사본이라 자동 반영되지 않습니다."
    say "갱신: cd $REPO && git pull && $0 --project $PROJDIR --copy"
  fi
else
  say "일부가 설치되지 않았습니다. 위 목록을 확인하세요."
fi

if [ "$SCOPE" = project ]; then
  say
  say "이 프로젝트에서만 적용됩니다: $DEST"
  say "문서에 적힌 ~/.claude/skills/... 경로는 전역 설치 기준입니다."
  say "프로젝트 설치에서는 $DEST/skills/... 로 읽으세요."
  if [ "$MODE" = copy ]; then
    say
    say "복사본을 커밋하고 싶지 않으면 $PROJDIR/.gitignore 에 넣으세요:"
    say "  .claude/skills/"
    say "  .claude/agents/"
    say "  .claude/$MANIFEST_NAME"
  fi
fi

say
say "다음 단계"
say "  커밋 훅:     $DEST/skills/hooks/install-hooks.sh <repo>"
say "  repo 프로필: $DEST/skills/shared/scripts/repo-profile.sh <repo>"
say "  해제:        $0 $([ "$SCOPE" = project ] && echo "--project $PROJDIR ")--uninstall"
[ "$OK" -eq 1 ] || exit 1
