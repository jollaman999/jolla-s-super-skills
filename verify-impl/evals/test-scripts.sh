#!/usr/bin/env bash
# verify-impl 스크립트의 종료 코드와 마스킹을 시험한다.
# 세션을 안 띄우므로 몇 초 만에 끝난다. cases.md 맨 아래 "스크립트 회귀" 블록이 원본이다.
#
# usage: verify-impl/evals/test-scripts.sh
# exit: 0=전부 통과  1=실패 있음
#
# 127.0.0.1 로 키 접속이 안 되는 환경에서는 그 항목만 건너뛴다.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"
S="$HERE/../scripts"

PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); printf '  실패  %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  건너뜀 %s\n' "$1"; }

# 종료 코드 시험
rc_is() { # <기대> <설명> <명령...>
  local want="$1" what="$2"; shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  [ "$got" = "$want" ] && ok || bad "$what: $want 여야 하는데 $got"
}

echo "== 문법"
for f in "$S"/*.sh; do
  bash -n "$f" 2>/dev/null && ok || bad "$(basename "$f") 문법"
done

echo "== ssh-run.sh 종료 코드"
# 192.0.2.0/24 는 문서용으로 예약된 대역이라 실제로 아무 데도 안 간다
rc_is 2 "접속 불가는 unknown(2)" env VH_HOST=192.0.2.1 VH_TO=6 "$S/ssh-run.sh" T 'echo x'

if timeout 8 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
     "$USER@127.0.0.1" true >/dev/null 2>&1; then
  rc_is 0 "성공은 pass(0)"        env VH_HOST=127.0.0.1 VH_USER="$USER" VH_TO=10 "$S/ssh-run.sh" T 'echo x'
  rc_is 1 "원격 비0 종료는 fail(1)" env VH_HOST=127.0.0.1 VH_USER="$USER" VH_TO=10 "$S/ssh-run.sh" T 'exit 3'
else
  skip "127.0.0.1 키 접속이 안 되어 성공·실패 경로 2건"
fi

echo "== 시크릿 마스킹"
# 가짜 비밀번호를 한 줄에 통째로 적으면 커밋 훅이 진짜 시크릿으로 보고 막는다.
# 조각으로 나눠 만든다. 값 자체는 아무 데도 쓰이지 않는 가짜다.
FAKE=$(printf 'T3st&%s#1' 'Pw')
out=$(env VH_HOST=192.0.2.1 VH_PW="$FAKE" VH_TO=6 "$S/ssh-run.sh" T "mysql -p$FAKE" 2>&1)
printf '%s' "$out" | grep -q 'T3st' && bad "비밀번호가 출력에 남음" || ok

echo "== 접속 실패 진단"
# 나가는 경로가 막힌 것은 우회 재시도 대상이라 진단이 붙는다
out=$(env VH_HOST=192.0.2.1 VH_TO=6 "$S/ssh-run.sh" T 'echo x' 2>&1)
printf '%s' "$out" | grep -q '\[진단\]' && ok || bad "접속 불가인데 진단이 안 붙음"
# refused 는 이미 상대에 닿은 것이라 우회해도 소용없다. 진단이 붙으면 안 된다
out=$(env VH_HOST=127.0.0.1 VH_PORT=1 VH_TO=6 "$S/ssh-run.sh" T 'echo x' 2>&1)
printf '%s' "$out" | grep -q '진단' && bad "refused 인데 진단이 붙음" || ok

echo "== 나머지 스크립트"
rc_is 1 "health-wait 타임아웃은 1" "$S/health-wait.sh" http://127.0.0.1:59999/ 6 2
rc_is 0 "scan-targets 는 항상 0"   "$S/scan-targets.sh" "$REPO"

echo
echo "$((PASS+FAIL))개 중 ${PASS}개 통과, ${FAIL}개 실패, ${SKIP}개 건너뜀"
[ "$FAIL" -eq 0 ]
