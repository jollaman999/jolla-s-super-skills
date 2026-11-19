#!/usr/bin/env bash
# until-guard.py 의 판정을 시험한다. 세션을 안 띄우므로 1초 안에 끝난다.
#
# 시험 명령은 지난 세션에서 실제로 나간 명령의 모양을 그대로 쓴다. 경로·호스트·계정만 일반 이름으로 바꿨다.
# "(문법 변형)" 이 붙은 것은 실제 기록에 없던 쓰는 방식(do 를 다음 줄에, bash -c 안에)을 판정기가 따라가는지 보는 것이다.
#
# usage: shared/scripts/test-until-guard.sh
# exit: 0=전부 통과  1=실패 있음  2=python 없음
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
G="$HERE/until-guard.py"
PY=$(command -v python3 || command -v python) || { echo "python 이 없습니다"; exit 2; }

PASS=0; FAIL=0

# chk <deny|allow> <설명> [도구이름]   명령은 stdin 으로 받는다
chk() {
  local want="$1" what="$2" tool="${3:-Bash}" cmd out got
  cmd=$(cat)
  out=$(printf '%s' "$cmd" | "$PY" -c '
import json, sys
print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"command": sys.stdin.read()}}))' "$tool" | "$PY" "$G")
  local rc=$?
  if [ "$rc" -ne 0 ]; then FAIL=$((FAIL+1)); printf '  실패  %s: 종료 코드 %s\n' "$what" "$rc"; return; fi
  if printf '%s' "$out" | grep -q '"permissionDecision": "deny"'; then got=deny; else got=allow; fi
  if [ "$got" = "$want" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); printf '  실패  %s: %s 여야 하는데 %s\n' "$what" "$want" "$got"; fi
}

echo "== 막아야 하는 것"
chk deny "조건 안의 timeout 은 루프 상한이 아니다" <<'CMD'
until timeout 20 ssh -n -o BatchMode=yes deploy@host.invalid 'test -s ~/work/out.pdf'; do sleep 20; done
CMD
chk deny "while ! 대신 쓴 while 폴링 (pgrep -f 가 자기 자신을 잡아 영영 안 끝나는 모양)" <<'CMD'
while pgrep -f "migrate.sh csp (gcp|nhn) --yes" >/dev/null; do sleep 30; done
CMD
chk deny "프로세스가 끝나기를 기다림" <<'CMD'
until ! kill -0 50350 2>/dev/null; do sleep 5; done
CMD
chk deny "출력 파일에 끝 표시가 나오기를 기다림" <<'CMD'
f=/tmp/w/tasks/b38.output; until grep -q '^exit=' "$f"; do sleep 5; done; cat "$f"; echo ===
CMD
chk deny "조건이 둘인 until" <<'CMD'
until [ -s /tmp/w/tasks/b2.output ] && grep -q real /tmp/w/tasks/b2.output; do sleep 15; done; cat /tmp/w/tasks/b2.output
CMD
chk deny "(문법 변형) do 가 다음 줄" <<'CMD'
until curl -sf http://127.0.0.1:8080/health
do
  sleep 2
done
CMD
chk deny "(문법 변형) timeout 없는 bash -c 안" <<'CMD'
bash -c 'until [ -f /tmp/w/done ]; do sleep 1; done'
CMD
chk deny "(문법 변형) timeout 없는 ssh 에 넘긴 셸 heredoc" <<'CMD'
ssh deploy@host.invalid bash <<'EOF'
until systemctl is-active --quiet app; do sleep 3; done
EOF
CMD

echo "== 통과시켜야 하는 것"
chk allow "카운터와 break" <<'CMD'
cd /tmp/w/t28; n=0; until [ -e done-fin.txt ]; do n=$((n+1)); [ $n -ge 16 ] && break; sleep 10; done; ls | grep -c fin
CMD
chk allow "조건 안의 카운터" <<'CMD'
F=/tmp/w/tasks/b3.output; until grep -q '^B: ' $F || [ $((i+=1)) -gt 70 ]; do sleep 3; done; sleep 4; cat $F
CMD
chk allow "루프 전체를 timeout bash -c 로 감쌈" <<'CMD'
timeout 175 bash -c 'until [ -s /tmp/w/tasks/bv.output ]; do sleep 10; done'; cat /tmp/w/tasks/bv.output
CMD
chk allow "timeout ssh 안의 카운터 루프" <<'CMD'
timeout 110 ssh -n -o BatchMode=yes deploy@host.invalid 'i=0; until grep -q BUILD_EXIT ~/work/build.log || [ $i -ge 10 ]; do sleep 10; i=$((i+1)); done; tail -2 ~/work/build.log'
CMD
chk allow "파일로 쓰는 heredoc 본문은 실행이 아니다" <<'CMD'
cat > /tmp/w/wait.sh <<'EOF'
#!/usr/bin/env bash
until [ -f "$1" ]; do sleep 1; done
EOF
chmod +x /tmp/w/wait.sh
CMD
chk allow "주석 안의 until" <<'CMD'
# poll until the document paints its first fill, then compare
for f in a b; do echo "$f"; done
CMD
chk allow "명령 옵션 --until" <<'CMD'
timeout 120 ssh -n deploy@host.invalid 'docker logs --since "2026-11-04T11:19:15" --until "2026-11-04T11:19:35" app 2>&1 | head -40'
CMD
chk allow "(문법 변형) 입력을 읽는 while 은 입력이 끝나면 끝난다" <<'CMD'
while read -r h; do timeout 10 ssh -n "$h" uptime; sleep 1; done < hosts.txt
CMD
chk allow "(문법 변형) timeout bash 에 넘긴 heredoc" <<'CMD'
timeout 300 bash <<'EOF'
until [ -f /tmp/w/ready ]; do sleep 2; done
EOF
CMD
chk allow "Bash 가 아닌 도구는 안 본다" Monitor <<'CMD'
until grep -q DONE /tmp/w/log; do sleep 5; done
CMD

echo "== 깨진 입력"
out=$(printf 'not json' | "$PY" "$G"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  실패  깨진 입력은 아무것도 안 내고 0 으로 끝나야 한다 (rc=$rc)"; fi

echo "통과 $PASS, 실패 $FAIL"
[ "$FAIL" -eq 0 ]
