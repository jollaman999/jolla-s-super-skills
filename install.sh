#!/usr/bin/env bash
# 이 repo 를 Claude Code 가 읽는 위치에 건다. 클론 위치는 어디든 상관없다.
#
# 설치 범위
#   전역     : ~/.claude       - 모든 프로젝트에 적용된다
#   프로젝트 : <dir>/.claude   - 그 프로젝트에서만 적용된다
#
# usage: install.sh [--global | --project <dir>] [--copy] [--force] [--dry-run] [--uninstall] [--yes]
#   --global      : 전역 설치. CLAUDE_CONFIG_DIR 가 있으면 그쪽을 쓴다
#   --project DIR : 그 프로젝트 안에만 설치한다 (DIR/.claude)
#   --copy        : 심볼릭 링크 대신 복사한다. 링크를 못 만드는 환경용
#   --force       : 이미 있는 일반 파일/디렉터리를 <이름>.bak.<날짜> 로 옮기고 덮어쓴다
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
FORCE=0; DRY=0; UNINSTALL=0; YES=0

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

# Git Bash 의 ln -s 는 기본 설정에서 링크를 못 만들면 조용히 "복사" 를 한다.
# 복사가 되면 git pull 해도 반영이 안 되는데 사용자는 링크인 줄 안다.
# nativestrict 를 켜면 못 만들 때 실패하므로 우리가 감지할 수 있다.
if is_windows; then
  export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict"
fi

# 링크 대상: <repo 안 경로>  <설치 위치 안 경로>
LINKS=(
  "CLAUDE.md:CLAUDE.md"
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

if [ -z "$SCOPE" ]; then
  if ask && [ "$UNINSTALL" -eq 0 ]; then choose_scope; else SCOPE=global; fi
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
    say "  설정 > 개인 정보 및 보안 > 개발자용 > 개발자 모드 를 켜고"
    say "  Git Bash 를 다시 연 뒤 이 스크립트를 다시 실행하면 링크로 설치됩니다."
  else
    say "  파일 시스템이 심볼릭 링크를 지원하지 않는 것 같습니다."
  fi
  say
}

if [ -z "$MODE" ] && [ "$DRY" -eq 0 ]; then
  if symlink_works "$DEST"; then
    MODE=link
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
[ -z "$MODE" ] && MODE=link

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
