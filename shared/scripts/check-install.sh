#!/usr/bin/env bash
# 설치된 것이 아직 살아 있는지 본다. 링크가 깨지면 skill 도 CLAUDE.md 도
# 아무 경고 없이 사라진다. `ls` 로는 링크가 멀쩡해 보이기 때문에 눈으로 못 가린다.
#
# usage: check-install.sh [설정디렉터리] [--quiet]
#   설정디렉터리 : 기본 $CLAUDE_CONFIG_DIR, 없으면 ~/.claude
#   --quiet      : 깨진 것이 있을 때만 출력한다 (SessionStart 훅이 쓰는 형태)
#                  훅이 부르면(CLAUDE_PROJECT_DIR 가 있고 표준 출력이 터미널이 아님) 알림을 바로 내지 않고
#                  <설정디렉터리>/.jolla-skills.broken 에 넘긴다. 훅이 이어서 부르는 self-update.sh 가
#                  업데이트 알림과 합쳐 훅 JSON 하나로 낸다. 훅 출력에 JSON 이 둘이면 Claude Code 가 못 읽는다.
#                  self-update.sh 를 부르지 않는 훅이면 스스로 훅 JSON 으로 낸다
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
BROKEN_NOTE="$DEST/.jolla-skills.broken"
UPDATER="$DEST/skills/shared/scripts/self-update.sh"

say(){ [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

# SessionStart 훅의 평문 출력은 Claude 맥락에만 가고 사용자 화면에는 안 뜬다. self-update.sh 와 같은 판정이다.
HOOK=0
[ "$QUIET" -eq 1 ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ ! -t 1 ] && HOOK=1

# 표준 입력을 JSON 문자열 하나로 바꾼다. self-update.sh 의 json_str 과 같다 (python 없는 Git Bash 용 awk).
json_str() {
  LC_ALL=C awk '
    BEGIN {
      for (i = 1; i < 32; i++) esc[sprintf("%c", i)] = sprintf("\\u%04x", i)
      esc["\t"] = "\\t"; esc["\r"] = "\\r"; esc["\""] = "\\\""; esc["\\"] = "\\\\"
    }
    {
      s = ""; n = length($0)
      for (i = 1; i <= n; i++) { c = substr($0, i, 1); s = s ((c in esc) ? esc[c] : c) }
      out = (NR > 1) ? out "\\n" s : s
    }
    END { printf "\"%s\"", out }'
}

# 이 훅이 이어서 self-update.sh 를 부르는가. 훅 명령은 그 파일을 실행할 수 있을 때만 부른다.
# 그 기능 전에 건 훅(settings.json 의 내 훅 명령에 self-update.sh 가 없음)은 안 부르므로 넘기면 알림이 사라진다.
updater_follows() {
  [ -x "$UPDATER" ] || return 1
  if grep -q 'check-install.sh' "$DEST/settings.json" 2>/dev/null \
     && ! grep -q 'self-update.sh' "$DEST/settings.json" 2>/dev/null; then
    return 1
  fi
  return 0
}

[ "$HOOK" -eq 1 ] && rm -f "$BROKEN_NOTE"

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
report() {
  printf 'skills 설치가 깨져 있습니다 (%d개 중 %d개).\n' "$((OK+BROKEN))" "$BROKEN"
  for b in "${BAD[@]}"; do printf '  %s\n' "$b"; done
  if [ -n "$SRC" ] && [ ! -d "$SRC" ]; then
    printf '  repo 가 %s 에 없습니다. 옮겼거나 지운 것으로 보입니다.\n' "$SRC"
  fi
  printf '고치기: cd <repo 경로> && ./install.sh%s\n' "$([ "$MODE" = copy ] && echo ' --copy')"
}

if [ "$HOOK" -eq 0 ]; then
  report
elif ! { updater_follows && report > "$BROKEN_NOTE"; }; then
  rm -f "$BROKEN_NOTE"
  m=$(report | json_str)
  printf '{"systemMessage":%s,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$m" "$m"
fi
exit 1
