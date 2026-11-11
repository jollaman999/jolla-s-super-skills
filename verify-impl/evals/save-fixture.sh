#!/usr/bin/env bash
# run.sh 가 남긴 회차 기록을 판정기 회귀용으로 보관한다. test-judge.sh 와 run.sh --rescore 가 읽는다.
#
# usage: verify-impl/evals/save-fixture.sh <기록 out.json 경로> <케이스> <pass|fail>
#   기록 경로 : run.sh 출력의 "기록: /tmp/.../out.json"
#   pass|fail : 그 회차의 **올바른** 판정. 판정기가 틀리게 찍은 회차면 run.sh 가 낸 것과 반대로 준다.
#               사람이 기록을 읽고 정한다. 손으로 만든 기록을 넣지 않는다.
#
# 보관 위치: <repo>/.claude/eval-fixtures/<케이스>/<pass|fail>/<id>/ (git 밖. 지우면 되살릴 수 없다)
#   out.json, proj/, cfg/ (로그인 정보·계정 정보·설치된 skill·플러그인·세션 jsonl 은 뺀다), sandbox.path
# exit: 0=보관함  2=사용법 오류
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"

[ $# -eq 3 ] || { sed -n '4,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
out="$1"; name="$2"; want="$3"
case "$want" in pass|fail) ;; *) echo "세 번째 인자는 pass 나 fail 입니다: $want" >&2; exit 2 ;; esac
[ -f "$HERE/cases/$name.rule" ] || { echo "케이스가 없습니다: $name" >&2; exit 2; }
[ -f "$out" ] || { echo "기록이 없습니다: $out" >&2; exit 2; }

sandbox="$(cd "$(dirname "$out")" && pwd -P)"
[ -d "$sandbox/proj" ] || { echo "run.sh 의 샌드박스가 아닙니다 (proj/ 없음): $sandbox" >&2; exit 2; }

dst="$REPO/.claude/eval-fixtures/$name/$want/$(basename "$sandbox")"
[ -e "$dst" ] && { echo "이미 있습니다: $dst" >&2; exit 2; }
mkdir -p "$dst"
cp "$out" "$dst/out.json"
cp -R "$sandbox/proj" "$dst/proj"
if [ -d "$sandbox/.claude" ]; then
  # 판정은 설정 폴더에서 유출금지 문자열만 찾고 *.jsonl 과 로그인 정보는 원래 안 본다.
  # .claude.json 은 계정 정보가 들어 있을 수 있어 뺀다
  ( cd "$sandbox/.claude" && find . -type f ! -name '.credentials.json' ! -name '.claude.json' ! -name '*.jsonl' \
      ! -path './skills/*' ! -path './plugins/*' ! -path './backups/*' -print0 ) \
    | ( cd "$sandbox/.claude" && while IFS= read -r -d '' f; do
          mkdir -p "$dst/cfg/$(dirname "$f")" && cp "$f" "$dst/cfg/$f"
        done )
fi
printf '%s\n' "$sandbox" > "$dst/sandbox.path"

# 보관본이 지금 판정기로 기대한 판정을 받는지 바로 보여준다
"$HERE/run.sh" --rescore "$dst" | head -5
echo "보관: $dst"
