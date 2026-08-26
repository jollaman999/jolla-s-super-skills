#!/usr/bin/env bash
# 같은 프로젝트에서 다른 Claude 세션이 동시에 돌고 있는지 확인한다.
# 충돌 위험을 판단하기 위한 정보 수집용. 판단은 호출한 쪽이 한다.
#
# usage: session-guard.sh [project_dir] [idle_min]
#   project_dir : 기본 $PWD
#   idle_min    : 이 시간 안에 활동한 세션을 "활성" 으로 본다 (기본 10분)
#
# env: CLAUDE_SESSION_ID  (내 세션. 있으면 목록에서 제외)
# exit: 0=동시 세션 없음  1=동시 세션 있음  2=확인 불가
set -uo pipefail
DIR="${1:-$PWD}"; IDLE="${2:-10}"
ME="${CLAUDE_SESSION_ID:-}"

DIR=$(cd "$DIR" 2>/dev/null && pwd -P) || { echo "확인 불가: 경로 없음"; exit 2; }
# 프로젝트 슬러그: /home/ish/git/cmp/x -> -home-ish-git-cmp-x
SLUG=$(printf '%s' "$DIR" | sed 's#/#-#g')
PROJ="$HOME/.claude/projects/$SLUG"

echo "프로젝트: $DIR"
[ -d "$PROJ" ] || { echo "세션 기록 없음 -> 동시 세션 없음"; exit 0; }

FOUND=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  sid=$(basename "$f" .jsonl)
  [ -n "$ME" ] && [ "$sid" = "$ME" ] && continue
  age=$(( ($(date +%s) - $(stat -c %Y "$f")) / 60 ))
  echo "  활성 세션: $sid  (마지막 활동 ${age}분 전)"
  # 그 세션이 최근 무엇을 건드렸는지 - 마지막 Edit/Write 대상
  tail -400 "$f" 2>/dev/null | python3 -c '
import sys,json
seen=[]
for l in sys.stdin:
    if "tool_use" not in l: continue
    try: d=json.loads(l)
    except: continue
    for c in (d.get("message",{}).get("content") or []):
        if isinstance(c,dict) and c.get("type")=="tool_use" and c.get("name") in ("Edit","Write","NotebookEdit"):
            p=(c.get("input") or {}).get("file_path")
            if p and p not in seen: seen.append(p)
for p in seen[-6:]: print("      최근 편집:", p)
' 2>/dev/null
  FOUND=1
done < <(find "$PROJ" -maxdepth 1 -name '*.jsonl' -mmin "-$IDLE" 2>/dev/null)

if [ $FOUND -eq 0 ]; then
  echo "동시 세션 없음 (최근 ${IDLE}분 기준)"
  exit 0
fi

# 워킹 트리 상태도 같이 알린다 - 충돌 판단 재료
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "  HEAD: $(git -C "$DIR" rev-parse --short HEAD 2>/dev/null) $(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  n=$(git -C "$DIR" status --porcelain 2>/dev/null | wc -l)
  echo "  워킹트리 변경: ${n}개"
  [ "$n" -gt 0 ] && git -C "$DIR" status --porcelain 2>/dev/null | head -8 | sed 's/^/      /'
fi
exit 1
