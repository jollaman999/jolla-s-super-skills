#!/usr/bin/env bash
# 이 repo 를 고쳤을 때 **따라가야 할 다른 repo** 후보를 찾는다.
# 판단은 하지 않는다. 후보와 근거만 낸다 - 고칠지는 사용자가 정한다.
#
# usage: downstream-scan.sh [repo] [옵션]
#   repo : 기본 $PWD
#   -q, --quiet   링크와 버전이 박힌 곳만 (가장 자주 놓치는 것)
#
# 심볼릭 링크로 연결된 곳은 항상 먼저 낸다. 링크는 글자가 아니라 grep 이 못 보는데,
# 고치면 그 자리에서 바로 영향이 간다 (`.git/hooks` 에 깔린 훅이 대표적이다).
#
# env: DOWNSTREAM_ROOTS  추가로 훑을 경로들 (':' 구분). 형제 디렉터리는 기본 포함이다.
#      예) DOWNSTREAM_ROOTS=~/git/terraform:~/문서/배포
#
# exit: 0=후보 있음  1=후보 없음  2=확인 불가
#
# 왜 필요한가 - 한 repo 를 고치고 연동 repo 반영을 빠뜨려서 같은 지시를 다시 받는 일이
# 6주 동안 29번 있었다. 사람이 매번 "저쪽 repo 도 반영해야지" 라고 말해 주고 있었다.
set -uo pipefail

QUIET=0; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quiet) QUIET=1; shift ;;
    -h|--help)  sed -n '2,17p' "$0"; exit 0 ;;
    *)          REPO="$1"; shift ;;
  esac
done
REPO="${REPO:-$PWD}"
REPO=$(cd "$REPO" 2>/dev/null && pwd -P) || { echo "확인 불가: 경로 없음" >&2; exit 2; }
NAME=$(basename "$REPO")
PARENT=$(dirname "$REPO")

# 폴더 이름은 흔한 영어 단어일 수 있다 (skills, core, common...). 그것만으로 찾으면
# 남의 repo 산문에 걸린다. 리모트에 적힌 진짜 repo 이름도 같이 검색어로 쓴다.
RNAME=$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -e 's#.*[/:]##' -e 's#\.git$##')
[ "$RNAME" = "$NAME" ] && RNAME=""

# 정규식에 넣을 것이라 메타문자를 죽인다
esc() { printf '%s' "$1" | sed 's#[][\.^$*+?(){}|/]#\\&#g'; }
NAME_RE=$(esc "$NAME")
RNAME_RE=$(esc "$RNAME")

# 이름이 나왔다고 참조가 아니다. 경로꼴이거나 리모트 이름일 때만 센다.
#   경로꼴  : /<이름>  또는  <이름>/     (~/.claude/skills/... , ai/skills)
#   리모트  : jolla-s-super-skills       (산문에 안 나오는 이름)
REF_RE="(/${NAME_RE}|${NAME_RE}/)"
[ -n "$RNAME" ] && REF_RE="${REF_RE}|${RNAME_RE}"

# 버전이 박힌 자리도 같은 이름 짝으로 본다
PIN_NAMES="$NAME_RE"
[ -n "$RNAME" ] && PIN_NAMES="${NAME_RE}|${RNAME_RE}"

# 훑을 대상: 형제 디렉터리 + DOWNSTREAM_ROOTS 아래 한 단계
TARGETS=()
for d in "$PARENT"/*/; do
  d="${d%/}"
  [ -d "$d" ] || continue
  [ "$d" = "$REPO" ] && continue
  TARGETS+=("$d")
done
IFS=':' read -r -a EXTRA <<< "${DOWNSTREAM_ROOTS:-}"
for r in ${EXTRA[@]+"${EXTRA[@]}"}; do
  r="${r/#\~/$HOME}"
  [ -d "$r" ] || continue
  for d in "$r"/*/; do
    d="${d%/}"
    [ -d "$d" ] && [ "$d" != "$REPO" ] && TARGETS+=("$d")
  done
done

[ ${#TARGETS[@]} -gt 0 ] || { echo "확인 불가: 훑을 형제 디렉터리가 없습니다"; exit 2; }

echo "# 연동 후보 - \`$NAME\` 을 참조하는 곳"
echo
echo "훑은 범위: $PARENT/* ${DOWNSTREAM_ROOTS:+· $DOWNSTREAM_ROOTS}"
echo

# 링크로 연결된 곳. 여기는 이름을 안 찾는다 - 링크를 따라가서 이 repo 안이면 확정이다.
# 추측이 아니라서 오탐이 없다. .git 안에 깔린 훅이 대표적이라 .git 을 빼지 않는다.
echo "## 링크로 연결된 곳 (고치면 즉시 영향)"
echo
LINKED=0
for d in "${TARGETS[@]}"; do
  out=$(find "$d" -type l 2>/dev/null | while read -r l; do
          t=$(readlink -f "$l" 2>/dev/null) || continue
          case "$t" in "$REPO"/*) printf '%s -> %s\n' "${l#"$d"/}" "${t#"$REPO"/}" ;; esac
        done | head -12)
  [ -n "$out" ] || continue
  LINKED=1
  echo "### $(basename "$d")"
  printf '%s\n' "$out" | sed 's/^/  /'
  echo
done
[ "$LINKED" = 1 ] || echo "  없음"
echo

# 버전이 고정된 줄. 여기를 안 고치면 배포는 성공하고 옛 버전이 실행된다.
echo "## 버전이 고정돼 있는 곳 (반영을 빠뜨려도 티가 안 나는 자리)"
echo
PINNED=0
for d in "${TARGETS[@]}"; do
  out=$(grep -rInE "(${PIN_NAMES})[:@/-]?v?[0-9]+\.[0-9]+(\.[0-9]+)?" "$d" \
        --include='*.yaml' --include='*.yml' --include='*.tf' --include='*.tfvars' \
        --include='*.json' --include='*.env' --include='Makefile' --include='*.mk' \
        --include='*.sh' --include='*.go' --include='*.md' \
        --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor 2>/dev/null | head -12)
  [ -n "$out" ] || continue
  PINNED=1
  echo "### $(basename "$d")"
  printf '%s\n' "$out" | sed "s#^$d/#  #" | cut -c1-160
  echo
done
[ "$PINNED" = 1 ] || echo "  없음"
echo

if [ "$QUIET" = 1 ]; then
  { [ "$PINNED" = 1 ] || [ "$LINKED" = 1 ]; } && exit 0
  exit 1
fi

echo "## 경로나 리모트 이름으로 참조하는 곳 (파일 수)"
echo
FOUND=0
for d in "${TARGETS[@]}"; do
  n=$(grep -rIlE "$REF_RE" "$d" \
      --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor \
      --exclude-dir=dist --exclude-dir=build 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] || continue
  FOUND=1
  printf '  %-28s %4s개 파일\n' "$(basename "$d")" "$n"
done
[ "$FOUND" = 1 ] || echo "  없음"
echo
echo "> 후보일 뿐이다. 실제로 따라가야 하는 것만 골라 \`.claude/downstream.md\` 에 기록하면"
echo "> 다음부터는 이 스캔 대신 그 파일을 본다."

[ "$FOUND" = 1 ] || [ "$PINNED" = 1 ] || [ "$LINKED" = 1 ]
