#!/usr/bin/env bash
# 이 repo 를 ~/.claude 에 심볼릭 링크로 건다. 클론 위치는 어디든 상관없다.
# 링크라서 repo 를 git pull 하면 바로 반영된다.
#
# usage: ./install.sh [--force] [--dry-run] [--uninstall]
#   --force     : 이미 있는 일반 파일/디렉터리를 <이름>.bak.<날짜> 로 옮기고 덮어쓴다
#   --dry-run   : 무엇을 할지만 출력하고 아무것도 안 바꾼다
#   --uninstall : 이 스크립트가 건 링크만 지운다 (남의 파일은 안 건드린다)
#
# exit: 0=정상  1=충돌로 중단  2=사용법 오류
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CLAUDE="${CLAUDE_HOME:-$HOME/.claude}"
FORCE=0; DRY=0; UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "usage: install.sh [--force] [--dry-run] [--uninstall]" >&2; exit 2 ;;
  esac
done

STAMP=$(date +%Y%m%d-%H%M%S)
CONFLICT=0
say(){ printf '%s\n' "$*"; }
run(){ [ "$DRY" -eq 1 ] && { say "    (dry-run) $*"; return 0; }; "$@"; }

# 링크 대상: <repo 안 경로>  <~/.claude 안 경로>
LINKS=(
  "CLAUDE.md:CLAUDE.md"
  "verify-impl:skills/verify-impl"
  "deploy-verify:skills/deploy-verify"
  "shared:skills/shared"
  "hooks:skills/hooks"
)

link_one(){ # <repo 상대경로> <claude 상대경로>
  local src="$REPO/$1" dst="$CLAUDE/$2"
  [ -e "$src" ] || { say "  건너뜀 $2   (원본 없음: $1)"; return; }
  run mkdir -p "$(dirname "$dst")"

  if [ -L "$dst" ]; then
    local cur; cur=$(readlink -f "$dst" 2>/dev/null || echo "")
    if [ "$cur" = "$(readlink -f "$src")" ]; then say "  그대로 $2"; return; fi
    say "  갱신   $2   (이전: $cur)"
    run ln -sfn "$src" "$dst"; return
  fi

  if [ -e "$dst" ]; then
    if [ "$FORCE" -eq 1 ]; then
      say "  대체   $2   (기존 것을 $2.bak.$STAMP 로 옮김)"
      run mv "$dst" "$dst.bak.$STAMP"
      run ln -sfn "$src" "$dst"
    else
      say "  충돌   $2   (링크가 아닌 파일이 이미 있음)"
      CONFLICT=1
    fi
    return
  fi

  say "  생성   $2"
  run ln -sfn "$src" "$dst"
}

unlink_one(){ # <repo 상대경로> <claude 상대경로>
  local src="$REPO/$1" dst="$CLAUDE/$2"
  if [ -L "$dst" ] && [ "$(readlink -f "$dst" 2>/dev/null)" = "$(readlink -f "$src" 2>/dev/null)" ]; then
    say "  제거   $2"; run rm -f "$dst"
  else
    say "  건너뜀 $2   (이 repo 가 건 링크가 아님)"
  fi
}

if [ "$UNINSTALL" -eq 1 ]; then
  say "해제: $REPO -> $CLAUDE"
  for e in "${LINKS[@]}"; do unlink_one "${e%%:*}" "${e##*:}"; done
  for f in "$REPO"/agents/*.md; do
    [ -e "$f" ] || continue
    unlink_one "agents/$(basename "$f")" "agents/$(basename "$f")"
  done
  say
  say "각 repo 의 .git/hooks 에 깐 훅은 그대로 남습니다."
  say "지우려면: rm <repo>/.git/hooks/{pre-commit,commit-msg} <repo>/.git/hooks/.profile"
  exit 0
fi

say "설치: $REPO -> $CLAUDE"
say
say "[skill 과 규칙]"
for e in "${LINKS[@]}"; do link_one "${e%%:*}" "${e##*:}"; done

say
say "[서브에이전트]"
N=0
for f in "$REPO"/agents/*.md; do
  [ -e "$f" ] || continue
  link_one "agents/$(basename "$f")" "agents/$(basename "$f")"
  N=$((N+1))
done
[ "$N" -eq 0 ] && say "  없음"

if [ "$CONFLICT" -eq 1 ]; then
  say
  say "충돌이 있어 일부를 걸지 않았습니다."
  say "기존 것을 살펴본 뒤, 덮어써도 되면: ./install.sh --force"
  exit 1
fi

if [ "$DRY" -eq 1 ]; then
  say
  say "dry-run 이라 아무것도 바꾸지 않았습니다."
  exit 0
fi

# --- 확인 ---
say
say "[확인]"
OK=1
for e in "${LINKS[@]}"; do
  d="$CLAUDE/${e##*:}"
  if [ -e "$d" ]; then say "  ok   ${e##*:}"; else say "  실패 ${e##*:}"; OK=0; fi
done
say "  ok   agents/*.md $N 개"

say
if [ "$OK" -eq 1 ]; then
  say "완료. 링크라서 이 repo 를 git pull 하면 바로 반영됩니다."
else
  say "일부가 걸리지 않았습니다. 위 목록을 확인하세요."
fi
say
say "다음 단계"
say "  커밋 훅:    ~/.claude/skills/hooks/install-hooks.sh <repo>"
say "  repo 프로필: ~/.claude/skills/shared/scripts/repo-profile.sh <repo>"
say "  해제:       $REPO/install.sh --uninstall"
[ "$OK" -eq 1 ] || exit 1
