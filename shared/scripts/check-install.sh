#!/usr/bin/env bash
# 설치된 것이 아직 살아 있는지 본다. 링크가 깨지면 skill 도 CLAUDE.md 도
# 아무 경고 없이 사라진다. `ls` 로는 링크가 멀쩡해 보이기 때문에 눈으로 못 가린다.
#
# usage: check-install.sh [설정디렉터리] [--quiet]
#   설정디렉터리 : 기본 $CLAUDE_CONFIG_DIR, 없으면 ~/.claude
#   --quiet      : 깨진 것이 있을 때만 출력한다 (SessionStart 훅이 쓰는 형태)
#
# exit: 0=전부 정상  1=깨진 것이 있음  2=설치 기록이 없음
#
# 왜 필요한가 - repo 를 옮기거나 지우면 링크 21개가 한 번에 끊긴다. 그런데
# 세션은 아무 말 없이 시작하고, 없어진 skill 은 목록에서 조용히 빠진다.
set -uo pipefail

QUIET=0; DEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet|-q) QUIET=1 ;;
    -h|--help)  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          DEST="$1" ;;
  esac
  shift
done
DEST="${DEST:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
MANIFEST="$DEST/.jolla-skills.manifest"

say(){ [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

if [ ! -f "$MANIFEST" ]; then
  say "[설치]  기록이 없습니다: $MANIFEST"
  say "  이 repo 가 아직 안 깔렸거나, 다른 설정 디렉터리에 깔려 있습니다."
  exit 2
fi

MODE=$(sed -n 's/^mode=//p' "$MANIFEST" | head -1)
SRC=$(sed -n 's/^repo=//p'  "$MANIFEST" | head -1)

say "[설치]  $DEST   (${MODE:-?}, repo=${SRC:-?})"

OK=0; BROKEN=0; BAD=()
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  d="$DEST/$rel"
  if [ -e "$d" ]; then
    OK=$((OK+1))
  else
    BROKEN=$((BROKEN+1))
    if [ -L "$d" ]; then BAD+=("$rel -> $(readlink "$d" 2>/dev/null) (대상 없음)")
    else                 BAD+=("$rel (없어짐)"); fi
  fi
done < <(sed -n 's/^path=//p' "$MANIFEST")

if [ "$BROKEN" -eq 0 ]; then
  say "  정상 $OK · 깨짐 0"
  exit 0
fi

# 깨졌을 때는 --quiet 여도 낸다. 이게 이 스크립트가 있는 이유다.
printf 'skills 설치가 깨져 있습니다 (%d개 중 %d개).\n' "$((OK+BROKEN))" "$BROKEN"
for b in "${BAD[@]}"; do printf '  %s\n' "$b"; done
if [ -n "$SRC" ] && [ ! -d "$SRC" ]; then
  printf '  repo 가 %s 에 없습니다. 옮겼거나 지운 것으로 보입니다.\n' "$SRC"
fi
printf '고치기: cd <repo 경로> && ./install.sh%s\n' "$([ "$MODE" = copy ] && echo ' --copy')"
exit 1
