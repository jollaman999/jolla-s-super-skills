#!/usr/bin/env bash
# 이 repo 를 고쳤을 때 **따라가야 할 다른 repo** 후보를 찾는다.
# 판단은 하지 않는다. 후보와 근거만 낸다 - 고칠지는 사용자가 정한다.
#
# usage: downstream-scan.sh [repo] [옵션]
#   repo : 기본 $PWD
#   -q, --quiet   버전이 박힌 곳만 (가장 자주 놓치는 것)
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
    -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
    *)          REPO="$1"; shift ;;
  esac
done
REPO="${REPO:-$PWD}"
REPO=$(cd "$REPO" 2>/dev/null && pwd -P) || { echo "확인 불가: 경로 없음" >&2; exit 2; }
NAME=$(basename "$REPO")
PARENT=$(dirname "$REPO")

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

# 버전이 고정된 줄. 여기를 안 고치면 배포는 성공하고 옛 버전이 실행된다.
echo "## 버전이 고정돼 있는 곳 (반영을 빠뜨려도 티가 안 나는 자리)"
echo
PINNED=0
for d in "${TARGETS[@]}"; do
  out=$(grep -rInE "${NAME}[:@/-]?v?[0-9]+\.[0-9]+(\.[0-9]+)?" "$d" \
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
  [ "$PINNED" = 1 ] && exit 0 || exit 1
fi

echo "## 이름만 참조하는 곳 (파일 수)"
echo
FOUND=0
for d in "${TARGETS[@]}"; do
  n=$(grep -rIl "$NAME" "$d" \
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

[ "$FOUND" = 1 ] || [ "$PINNED" = 1 ]
