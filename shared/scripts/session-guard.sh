#!/usr/bin/env bash
# 같은 프로젝트에서 다른 Claude 세션이 동시에 실행 중인지 확인한다.
# 충돌 위험을 판단하기 위한 정보 수집용. 판단은 호출한 쪽이 한다.
#
# usage: session-guard.sh [project_dir] [idle_min]
#   project_dir : 기본 $PWD
#   idle_min    : 이 시간 안에 활동한 세션을 "활성" 으로 본다 (기본 10분)
#
# env: CLAUDE_SESSION_ID  (내 세션. 있으면 목록에서 제외)
#      CLAUDE_CONFIG_DIR  (기본 $HOME/.claude)
# exit: 0=동시 세션 없음  1=동시 세션 있음  2=확인 불가
#
# 확인 불가(2)를 0 으로 뭉개지 않는다. 세션 기록을 못 찾은 것과 세션이 없는 것은 다르다.
# Windows(Git Bash)에서는 Claude Code 가 Windows 경로로 슬러그를 만들기 때문에
# POSIX 경로를 그대로 변환한 슬러그와 어긋난다. 그걸 "세션 없음" 으로 읽으면
# 동시 세션 보호가 통째로 무력화된다.
set -uo pipefail
DIR="${1:-$PWD}"; IDLE="${2:-10}"
ME="${CLAUDE_SESSION_ID:-}"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

have() { command -v "$1" >/dev/null 2>&1; }

DIR=$(cd "$DIR" 2>/dev/null && pwd -P) || { echo "확인 불가: 경로 없음"; exit 2; }
echo "프로젝트: $DIR"

ROOT="$CFG/projects"
[ -d "$ROOT" ] || {
  echo "확인 불가: 세션 기록 디렉터리가 없습니다 ($ROOT)"
  echo "  CLAUDE_CONFIG_DIR 를 다른 곳으로 두었다면 그 값을 넣어 다시 실행하세요"
  exit 2
}

# 슬러그 후보. Claude Code 는 작업 디렉터리 경로의 구분자를 '-' 로 바꿔 이름을 만든다.
#   Linux/WSL : /home/me/proj/app      -> -home-me-proj-app
#   Windows    : C:\Users\me\proj\app  -> Claude Code 가 보는 것은 Windows 경로다
CANDS=()
CANDS+=("$(printf '%s' "$DIR" | sed 's#/#-#g')")
if have cygpath; then
  for form in -w -m; do
    w=$(cygpath "$form" "$DIR" 2>/dev/null) || continue
    [ -n "$w" ] && CANDS+=("$(printf '%s' "$w" | sed 's#[\\/:]#-#g')")
  done
fi

PROJ=""
for c in "${CANDS[@]}"; do
  [ -n "$c" ] && [ -d "$ROOT/$c" ] && { PROJ="$ROOT/$c"; break; }
done

# 후보가 하나도 안 맞으면 경로 꼬리로 찾아본다. 슬러그 규칙을 모르는 환경 대비.
if [ -z "$PROJ" ]; then
  TAIL=$(printf '%s' "$DIR" | awk -F/ '{ n=NF; s=""; for (i=(n>2?n-2:1); i<=n; i++) if ($i != "") s = (s=="" ? $i : s "-" $i); print s }')
  MATCHES=$(find "$ROOT" -maxdepth 1 -mindepth 1 -type d -name "*$TAIL" 2>/dev/null)
  CNT=$(printf '%s\n' "$MATCHES" | grep -c . || true)
  if [ "$CNT" -eq 1 ]; then
    PROJ="$MATCHES"
    echo "  (슬러그 직접 대응 실패 - 경로 꼬리 '$TAIL' 로 찾음: $(basename "$PROJ"))"
  elif [ "$CNT" -eq 0 ]; then
    echo "확인 불가: 이 프로젝트의 세션 기록을 찾지 못했습니다"
    echo "  찾아본 이름: ${CANDS[*]} · 꼬리 '*$TAIL'"
    echo "  -> 세션이 없는 것인지 이름 규칙이 다른 것인지 구분할 수 없습니다. $ROOT 를 직접 확인하세요"
    exit 2
  else
    echo "확인 불가: 경로 꼬리 '$TAIL' 에 걸리는 디렉터리가 여러 개입니다"
    printf '%s\n' "$MATCHES" | sed 's#.*/#      #'
    exit 2
  fi
fi

# 파일 수정 시각 - GNU stat 이 없는 환경 대비
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# 최근 편집 목록은 부가 정보다. python 이 없으면 생략하되 조용히 넘기지 않는다.
PY=""
for c in python3 python py; do
  have "$c" && "$c" -c 'import sys' >/dev/null 2>&1 && { PY="$c"; break; }
done

FOUND=0
NOPY_WARNED=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  sid=$(basename "$f" .jsonl)
  [ -n "$ME" ] && [ "$sid" = "$ME" ] && continue
  now=$(date +%s); m=$(mtime "$f")
  if [ "$m" -gt 0 ]; then age=$(( (now - m) / 60 )); else age="?"; fi
  echo "  활성 세션: $sid  (마지막 활동 ${age}분 전)"
  # 그 세션이 최근 무엇을 건드렸는지 - 마지막 Edit/Write 대상
  if [ -n "$PY" ]; then
    tail -400 "$f" 2>/dev/null | "$PY" -c '
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
  elif [ "$NOPY_WARNED" -eq 0 ]; then
    echo "      (최근 편집 목록은 python 이 없어 생략합니다 - 세션 감지 자체는 정상)"
    NOPY_WARNED=1
  fi
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
