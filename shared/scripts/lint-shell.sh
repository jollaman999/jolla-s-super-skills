#!/usr/bin/env bash
# 셸 스크립트를 shellcheck 로 본다. bash -n 은 문법만 보고 지나가는 것들을 잡는다.
#
# usage: shared/scripts/lint-shell.sh [--all] [--level error|warning|info] [파일 ...]
#   기본       : 스테이지되거나 고친 셸 파일만
#   --all      : 이 repo 가 추적하는 셸 파일 전부
#   --level    : 어느 심각도까지 볼지 (기본 warning)
#   파일 지정  : 그 파일들만
#
# 셸 파일 판별은 확장자(.sh) 와 첫 줄 shebang 둘 다 본다. hooks/pre-commit 처럼
# 확장자가 없는 것이 있기 때문이다.
#
# exit: 0=지적 없음  1=지적 있음  2=shellcheck 이 없음
set -uo pipefail

LEVEL=warning; ALL=0; FILES=()

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all)     ALL=1 ;;
    --level)   shift; LEVEL="${1:-warning}" ;;
    -h|--help) usage; exit 0 ;;
    -*)        usage >&2; exit 2 ;;
    *)         FILES+=("$1") ;;
  esac
  shift
done

if ! command -v shellcheck >/dev/null; then
  echo "shellcheck 이 없습니다. 아래 중 하나로 설치하세요." >&2
  echo "  pipx install shellcheck-py     # 홈에만 깔립니다" >&2
  echo "  sudo apt install shellcheck" >&2
  exit 2
fi

is_shell() { # <경로>
  [ -f "$1" ] || return 1
  case "$1" in *.sh) return 0 ;; esac
  head -c 40 "$1" 2>/dev/null | head -1 | grep -qE '^#!.*[ /](bash|sh|dash|ksh)( |$)'
}

# 볼 파일 고르기
if [ "${#FILES[@]}" -eq 0 ]; then
  if [ "$ALL" -eq 1 ]; then
    mapfile -t CAND < <(git ls-files)
  else
    # 스테이지 + 워킹트리 변경분. 둘 다 없으면 전부 본다.
    mapfile -t CAND < <(git diff --name-only --diff-filter=ACM HEAD 2>/dev/null | sort -u)
    [ "${#CAND[@]}" -eq 0 ] && mapfile -t CAND < <(git ls-files)
  fi
  FILES=()
  for f in "${CAND[@]}"; do is_shell "$f" && FILES+=("$f"); done
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "볼 셸 파일이 없습니다."
  exit 0
fi

shellcheck -S "$LEVEL" -- "${FILES[@]}"
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "${#FILES[@]}개 파일, 지적 없음 (심각도 $LEVEL 이상)"
else
  echo "${#FILES[@]}개 파일에서 지적이 나왔습니다."
  echo "번호별 설명: https://www.shellcheck.net/wiki/SC####"
fi
exit "$rc"
