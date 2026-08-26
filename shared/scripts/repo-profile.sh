#!/usr/bin/env bash
# repo 의 커밋 스타일과 코드 스타일을 뽑는다. 첫 커밋 전에 물어볼 근거를 만드는 용도.
# 판단은 호출한 쪽이 한다. 이 스크립트는 사실만 낸다.
#
# usage: repo-profile.sh [repo] [n] [--save]
#   repo   : 기본 $PWD
#   n      : 분석할 커밋 수 (기본 200)
#   --save : 결과를 <repo>/.claude/repo-profile.md 에 쓴다
#
# exit: 0=정상  2=repo 아님/커밋 없음
set -uo pipefail

DIR="$PWD"; N=200; SAVE=0
for a in "$@"; do
  case "$a" in
    --save) SAVE=1 ;;
    ''|*[!0-9]*) DIR="$a" ;;
    *) N="$a" ;;
  esac
done
DIR=$(cd "$DIR" 2>/dev/null && pwd -P) || { echo "경로 없음" >&2; exit 2; }
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || { echo "git repo 아님: $DIR" >&2; exit 2; }

g(){ git -C "$DIR" "$@"; }
pct(){ [ "${2:-0}" -eq 0 ] && { echo 0; return; }; echo $(( $1 * 100 / $2 )); }

# --- 분석 대상 커밋 고르기 ---
# 내 커밋이 충분히 있으면 내 것만 본다. 적으면 repo 전체를 보고 그렇다고 밝힌다.
ME=$(g config user.name 2>/dev/null || echo "")
SCOPE_NOTE="repo 전체"
AUTHOPT=()
if [ -n "$ME" ]; then
  MINE=$(g log --author="$ME" --oneline -n 60 2>/dev/null | wc -l)
  if [ "$MINE" -ge 20 ]; then
    AUTHOPT=(--author="$ME")
    SCOPE_NOTE="$ME 의 커밋"
  fi
fi

# Revert/Merge 는 자동 생성 제목이라 본인 스타일이 아니다. 제외하고 센다.
SUBJ=$(g log "${AUTHOPT[@]}" --no-merges -n "$N" --format='%s' 2>/dev/null \
       | grep -vE '^(Revert |Reapply |Merge |fixup! |squash! )')
TOTAL=$(printf '%s\n' "$SUBJ" | grep -c . )
[ "$TOTAL" -eq 0 ] && { echo "분석할 커밋이 없습니다: $DIR" >&2; exit 2; }

# --- 커밋: 언어 ---
KO=$(printf '%s\n' "$SUBJ" | grep -cE '[가-힣]')
LANG_VERDICT="영어"
[ "$(pct "$KO" "$TOTAL")" -ge 60 ] && LANG_VERDICT="한글"
[ "$(pct "$KO" "$TOTAL")" -ge 20 ] && [ "$(pct "$KO" "$TOTAL")" -lt 60 ] && LANG_VERDICT="한글/영어 혼용"

# --- 커밋: 접두사 체계 ---
CONV_RE='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]*\))?!?: '
SCOPE_RE='^[^ :]+(, *[^ :,]+)*: '
CONV=$(printf '%s\n' "$SUBJ" | grep -cE "$CONV_RE")
SCOPED=$(printf '%s\n' "$SUBJ" | grep -vE "$CONV_RE" | grep -cE "$SCOPE_RE")
NONE=$(( TOTAL - CONV - SCOPED ))
PREFIX_VERDICT="접두사 없음"
if [ "$CONV" -ge "$SCOPED" ] && [ "$(pct "$CONV" "$TOTAL")" -ge 40 ]; then
  PREFIX_VERDICT="conventional (fix: / feat: ...)"
elif [ "$(pct "$SCOPED" "$TOTAL")" -ge 40 ]; then
  PREFIX_VERDICT="스코프형 (모듈명: ...)"
elif [ $(( CONV + SCOPED )) -gt "$NONE" ]; then
  PREFIX_VERDICT="conventional/스코프형 혼용"
fi

# 다중 스코프를 콤마로 잇는지 (커널 계열에서 흔하다)
MULTI=$(printf '%s\n' "$SUBJ" | grep -cE '^[^ :]+, *[^ :,]+.*: ')

# --- 커밋: 제목 길이 (한글은 바이트가 아니라 글자로 센다) ---
LENS=$(while IFS= read -r l; do [ -n "$l" ] && echo "${#l}"; done <<< "$SUBJ" | sort -n)
LN=$(printf '%s\n' "$LENS" | grep -c .)
MED=$(printf '%s\n' "$LENS" | sed -n "$(( LN / 2 + 1 ))p")
P90=$(printf '%s\n' "$LENS" | sed -n "$(( LN * 9 / 10 + 1 ))p")
MAXL=$(printf '%s\n' "$LENS" | tail -1)

# --- 커밋: 본문 / Signed-off-by / 머지 / 티켓 ---
BODYSTAT=$(g log "${AUTHOPT[@]}" --no-merges -n "$N" --format='%x02%b' 2>/dev/null \
  | awk 'BEGIN{RS="\002"} NR>1{ s=$0; gsub(/^[ \t\r\n]+|[ \t\r\n]+$/,"",s);
        if (s=="") e++; else if (s ~ /^This rever(ts|t) commit/) e++; else b++ }
        END{ printf "%d %d", b+0, b+e }')
BODY_Y=${BODYSTAT%% *}; BODY_T=${BODYSTAT##* }
SOB=$(g log "${AUTHOPT[@]}" --no-merges -n "$N" --format='%b' 2>/dev/null | grep -ci '^Signed-off-by:')
MERGES=$(g log "${AUTHOPT[@]}" --merges -n "$N" --oneline 2>/dev/null | wc -l)
TICKET=$(printf '%s\n' "$SUBJ" | grep -cE '([A-Z][A-Z0-9]+-[0-9]+|#[0-9]+)')

# --- 코드: 표본 고르기 ---
# 랜덤한 tracked 파일보다 그 사람이 최근에 만진 파일이 스타일을 더 잘 보여준다.
SRC_RE='\.(c|h|cc|cpp|hpp|go|java|kt|py|rb|rs|ts|tsx|js|jsx|sh|pl|php|swift|scala|tf)$'
FILES=$(g log "${AUTHOPT[@]}" -n "$N" --name-only --diff-filter=AM --format='' 2>/dev/null \
        | grep -E "$SRC_RE" | sort -u | head -200)
# 삭제된 파일이 목록에 남아 있으므로 지금 존재하는 것만 남긴다.
CAND=""
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$DIR/$f" ] && CAND+="$f"$'\n'
done <<< "$FILES"
# 그래도 비면 tracked 전체에서 다시 고른다 (커밋이 문서뿐인 repo)
if [ -z "${CAND//[$'\n' ]/}" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$DIR/$f" ] && CAND+="$f"$'\n'
  done <<< "$(g ls-files 2>/dev/null | grep -E "$SRC_RE" | head -200)"
fi
SAMPLE=$(printf '%s' "$CAND" | grep -c . || true)

INDENT=""; CLANG=""
CODE_BLOCK="대상 파일 없음 - 코드 분석을 건너뜁니다."
if [ "${SAMPLE:-0}" -gt 0 ]; then
  # 확장자 분포에서 주력 언어를 정한다
  TOPEXT=$(printf '%s\n' "$CAND" | sed -E 's/.*\.([A-Za-z]+)$/\1/' | sort | uniq -c | sort -rn | head -1 | awk '{print $2" ("$1"개)"}')
  PICK=$(printf '%s\n' "$CAND" | head -40)

  TAB=0; SPC=0; L80=0; L100=0; L120=0; LTOT=0; CKO=0; CTOT=0; SLASH=0; BLOCK=0
  while IFS= read -r f; do
    [ -f "$DIR/$f" ] || continue
    # 블록 주석 연속행(' *')은 인덴트 판정에서 뺀다. 스페이스로 오인된다.
    # grep -c 는 0건일 때 "0" 을 찍고 exit 1 이다. || echo 0 을 붙이면 "0\n0" 이 되어
    # 산술식이 깨진다. 상태는 무시하고 출력만 쓴다.
    TAB=$(( TAB + $(grep -c $'^\t' "$DIR/$f" 2>/dev/null) ))
    SPC=$(( SPC + $(grep -cE '^ {2,}[^ *]' "$DIR/$f" 2>/dev/null) ))
    LTOT=$(( LTOT + $(wc -l < "$DIR/$f" 2>/dev/null) ))
    L80=$(( L80 + $(awk 'length>80' "$DIR/$f" 2>/dev/null | wc -l) ))
    L100=$(( L100 + $(awk 'length>100' "$DIR/$f" 2>/dev/null | wc -l) ))
    L120=$(( L120 + $(awk 'length>120' "$DIR/$f" 2>/dev/null | wc -l) ))
    C=$(grep -hE '(^|[[:space:]])(//|#|\*|--)' "$DIR/$f" 2>/dev/null)
    CTOT=$(( CTOT + $(printf '%s\n' "$C" | grep -c .) ))
    CKO=$(( CKO + $(printf '%s\n' "$C" | grep -cE '[가-힣]') ))
    SLASH=$(( SLASH + $(grep -c '//' "$DIR/$f" 2>/dev/null) ))
    BLOCK=$(( BLOCK + $(grep -c '/\*' "$DIR/$f" 2>/dev/null) ))
  done <<< "$PICK"

  # 주석 형태는 C 계열에서만 의미가 있다. 셸에서는 URL 의 // 와 글롭의 /* 를 센다.
  CMTFORM=""
  case "$TOPEXT" in
    c\ *|h\ *|cc\ *|cpp\ *|hpp\ *|go\ *|java\ *|kt\ *|ts\ *|tsx\ *|js\ *|jsx\ *|rs\ *|swift\ *|scala\ *|php\ *)
      CMTFORM=$'\n'"| 주석 형태 | \`//\` $SLASH · \`/* */\` $BLOCK |" ;;
  esac

  INDENT="탭"; [ "$SPC" -gt "$TAB" ] && INDENT="스페이스"
  CLANG="영어"
  [ "$(pct "$CKO" "$CTOT")" -ge 50 ] && CLANG="한글"
  [ "$(pct "$CKO" "$CTOT")" -ge 15 ] && [ "$(pct "$CKO" "$CTOT")" -lt 50 ] && CLANG="한글/영어 혼용"

  CODE_BLOCK=$(cat <<EOF
| 항목 | 값 |
|------|-----|
| 주력 확장자 | $TOPEXT |
| 표본 | $(printf '%s\n' "$PICK" | grep -c .) 개 파일, $LTOT 줄 |
| 인덴트 | **$INDENT** (탭 $TAB 줄 / 스페이스 $SPC 줄) |
| 행 길이 | 80칸 초과 $(pct $L80 $LTOT)% · 100칸 $(pct $L100 $LTOT)% · 120칸 $(pct $L120 $LTOT)% |
| 주석 언어 | **$CLANG** (주석 $CTOT 줄 중 한글 $CKO 줄) |$CMTFORM
EOF
)
fi

# --- 출력 ---
OUT=$(cat <<EOF
# repo 프로필

- 대상: \`$DIR\`
- 분석 범위: $SCOPE_NOTE 중 최근 $TOTAL 개 (Revert/Merge 제외)
- 뽑은 날: $(date +%F)

## 커밋 스타일

| 항목 | 값 |
|------|-----|
| 언어 | **$LANG_VERDICT** (한글 제목 $KO/$TOTAL = $(pct $KO $TOTAL)%) |
| 접두사 | **$PREFIX_VERDICT** (conventional $CONV · 스코프형 $SCOPED · 없음 $NONE) |
| 다중 스코프 | \`모듈1, 모듈2:\` 형태 $MULTI 개 |
| 제목 길이 | 중앙값 **$MED자** · p90 $P90자 · 최대 $MAXL자 |
| 본문 | $BODY_Y/$BODY_T = $(pct $BODY_Y $BODY_T)% 가 본문 있음 |
| Signed-off-by | $SOB 개 $([ "$SOB" -eq 0 ] && echo "(안 씀)") |
| 머지 커밋 | $MERGES 개 $([ "$MERGES" -eq 0 ] && echo "(전부 rebase/cherry-pick)") |
| 티켓번호 | 제목에 $TICKET 개 $([ "$TICKET" -eq 0 ] && echo "(제목에 안 넣음)") |

### 접두사 top 10
\`\`\`
$(printf '%s\n' "$SUBJ" | grep -oE '^[^:]{1,40}:' | sort | uniq -c | sort -rn | head -10)
\`\`\`

### 접두사 뒤 첫 단어 top 8
\`\`\`
$(printf '%s\n' "$SUBJ" | sed -E 's/^[^:]{1,40}: *//' | awk '{print $1}' | sort | uniq -c | sort -rn | head -8)
\`\`\`

### 최근 제목 10개
\`\`\`
$(printf '%s\n' "$SUBJ" | head -10)
\`\`\`

## 코드 스타일

$CODE_BLOCK

## 확인받을 것

> 이 repo 는 $LANG_VERDICT + $PREFIX_VERDICT 이고 제목 중앙값이 ${MED}자입니다.
> 주석은 ${CLANG:-미확인}, 인덴트는 ${INDENT:-미확인} 입니다. 이대로 갈까요?
EOF
)

printf '%s\n' "$OUT"

if [ "$SAVE" -eq 1 ]; then
  mkdir -p "$DIR/.claude"
  printf '%s\n' "$OUT" > "$DIR/.claude/repo-profile.md"
  echo
  echo "저장: $DIR/.claude/repo-profile.md"
fi
