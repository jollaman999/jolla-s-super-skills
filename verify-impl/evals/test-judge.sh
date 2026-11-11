#!/usr/bin/env bash
# 판정기 회귀 시험. 보관한 실제 세션 기록을 지금 판정기로 다시 판정해서
# pass/ 에 둔 것은 통과, fail/ 에 둔 것은 실패로 나오는지 본다. 세션을 안 띄워서 몇 초에 끝난다.
#
# 판정기(run.sh 의 판별 함수, cases/*.rule)를 고쳤으면 이것부터 돌린다.
# 기록은 save-fixture.sh 로 보관한다. 손으로 만든 기록은 넣지 않는다 - 실제 기록은
# jq·도구 출력을 거쳐 손으로 쓴 것과 모양이 다르고, 그 차이에서 판정기 결함이 나왔다.
#
# usage: verify-impl/evals/test-judge.sh [보관 폴더]   (기본 <repo>/.claude/eval-fixtures)
# exit: 0=전부 기대대로  1=어긋난 것 있음  2=보관한 기록이 없음
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"
ROOT="${1:-$REPO/.claude/eval-fixtures}"

n=0; bad=0
for fx in "$ROOT"/*/pass/* "$ROOT"/*/fail/*; do
  [ -d "$fx" ] || continue
  n=$((n+1))
  want=$(basename "$(dirname "$fx")")
  res=$("$HERE/run.sh" --rescore "$fx")
  got=$(printf '%s\n' "$res" | head -1 | awk '{print $1}')
  if [ "$got" != "$want" ]; then
    bad=$((bad+1))
    printf '어긋남  기대 %s, 판정 %s: %s\n' "$want" "$got" "${fx#$ROOT/}"
    printf '%s\n' "$res" | tail -n +2
  fi
done

[ "$n" -gt 0 ] || { echo "보관한 기록이 없습니다: $ROOT (save-fixture.sh 로 보관)" >&2; exit 2; }
echo "기록 ${n}건 중 $((n-bad))건 기대대로"
[ "$bad" -eq 0 ]
