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

echo "== 비밀번호 전달과 sshpass-win32 출력 정리"
# sshpass·uname·cygpath 를 가짜로 세워 접속 없이 본다. 가짜 sshpass 는 받은 인자와 SSHPASS 를 적고
# sshpass-win32 가 ConPTY 로 내는 모양(앞 빈 줄, ESC[?..., CR)을 흉내 낸 출력을 낸다.
T=$(mktemp -d); mkdir -p "$T/bin" "$T/win/System32/OpenSSH"; : > "$T/win/System32/OpenSSH/ssh.exe"
cat > "$T/bin/sshpass" <<STUB
#!/usr/bin/env bash
if [ "\$1" = -V ]; then
  [ -n "\${STUB_REAL:-}" ] && { echo "sshpass 1.10"; exit 0; }
  echo "error: unknown option \\\`-V\\\`"; exit 1
fi
printf '%s\n' "\$@" > "$T/args"; printf '%s|%s\n' "\${SSHPASS:-}" "\${MSYS2_ARG_CONV_EXCL:-}" > "$T/env"
printf '\n\033[?25lremote-out\r\n\033[?9001l\033[?1004l'
STUB
printf '#!/bin/sh\necho "${STUB_OS:-MINGW64_NT-10.0}"\n' > "$T/bin/uname"
printf '#!/bin/sh\ncase "$1" in -u) echo "%s/win" ;; -w) echo "W:\\\\ssh.exe" ;; esac\n' "$T" > "$T/bin/cygpath"
chmod 755 "$T/bin/sshpass" "$T/bin/uname" "$T/bin/cygpath"
FAKE=$(printf 'T3st&%s#2' 'Pw')
ev() { sed -E 's/.*"evidence":("([^"\\]|\\.)*").*/\1/'; }
out=$(env PATH="$T/bin:$PATH" VH_HOST=192.0.2.1 VH_PW="$FAKE" VH_TO=6 "$S/ssh-run.sh" T 'echo x' 2>&1)
grep -qF "$FAKE" "$T/args" && bad "비밀번호가 sshpass 인자에 들어감" || ok
[ "$(cat "$T/env")" = "$FAKE|*" ] && ok || bad "SSHPASS 나 경로 변환 끄기가 안 넘어감: $(sed "s/$FAKE/***/" "$T/env")"
[ "$(head -2 "$T/args" | tr '\n' ' ')" = '-e W:\ssh.exe ' ] && ok || bad "sshpass-win32 인데 Windows OpenSSH 를 안 고름: $(head -2 "$T/args" | tr '\n' ' ')"
grep -qx 'UserKnownHostsFile=NUL' "$T/args" && grep -qx 'PubkeyAuthentication=no' "$T/args" && ok || bad "NUL·PubkeyAuthentication=no 가 안 붙음"
[ "$(printf '%s' "$out" | ev)" = '"remote-out"' ] && ok || bad "ConPTY 제어 문자·CR·빈 줄이 남음: $(printf '%s' "$out" | ev)"
# Windows OpenSSH 가 없으면 PATH 의 ssh 를 쓰고 이유를 남긴다
rm "$T/win/System32/OpenSSH/ssh.exe"
out=$(env PATH="$T/bin:$PATH" VH_HOST=192.0.2.1 VH_PW="$FAKE" VH_TO=6 "$S/ssh-run.sh" T 'echo x' 2>&1)
[ "$(head -2 "$T/args" | tr '\n' ' ')" = '-e ssh ' ] && printf '%s' "$out" | grep -q 'Windows OpenSSH.*없어' && ok || bad "Windows OpenSSH 없음 안내가 안 붙음"
# 리눅스(원래 sshpass)는 출력을 건드리지 않는다
out=$(env PATH="$T/bin:$PATH" STUB_OS=Linux STUB_REAL=1 VH_HOST=192.0.2.1 VH_PW="$FAKE" VH_TO=6 "$S/ssh-run.sh" T 'echo x' 2>&1)
[ "$(printf '%s' "$out" | ev)" = '"\n[?25lremote-out\r\n[?9001l[?1004l"' ] && ok || bad "리눅스 출력이 바뀜: $(printf '%s' "$out" | ev)"
grep -qx 'UserKnownHostsFile=/dev/null' "$T/args" && grep -qx 'PubkeyAuthentication=no' "$T/args" && ok || bad "리눅스 비밀번호 접속 옵션이 다름"
rm "$T/args" "$T/env" "$T/bin/sshpass" "$T/bin/uname" "$T/bin/cygpath"
rmdir "$T/bin" "$T/win/System32/OpenSSH" "$T/win/System32" "$T/win" "$T"

echo "== session-guard 슬러그"
# Claude Code 는 경로의 영숫자가 아닌 글자를 한 글자당 '-' 하나로 바꿔 세션 기록 폴더를 만든다.
# '/' 만 바꾸면 '.' '_' 한글이 든 경로에서 기록을 못 찾아 exit 2 가 난다.
# 기대 이름은 스크립트와 따로 python 으로 만든다. 같은 함수로 만들면 같이 틀려도 통과한다.
SG="$REPO/shared/scripts/session-guard.sh"
if command -v python3 >/dev/null 2>&1; then
  T=$(mktemp -d)
  P="$T/a_b.c/포스코"; mkdir -p "$P" "$T/cfg/projects"
  P=$(cd "$P" && pwd -P)
  want=$(python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9]","-",sys.argv[1]))' "$P")
  mkdir -p "$T/cfg/projects/$want"
  rc_is 0 "기록 폴더가 있고 세션이 없으면 0" env CLAUDE_CONFIG_DIR="$T/cfg" "$SG" "$P" 10
  touch "$T/cfg/projects/$want/s1.jsonl"
  rc_is 1 "'.' '_' 한글 경로의 활성 세션을 찾으면 1" env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR="$T/cfg" "$SG" "$P" 10
  rc_is 1 "C 로케일에서도 한글을 한 글자로 센다" env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID LC_ALL=C CLAUDE_CONFIG_DIR="$T/cfg" "$SG" "$P" 10
  rc_is 1 "다른 세션 ID 로 돌면 그대로 센다" env CLAUDE_CODE_SESSION_ID=nobody CLAUDE_SESSION_ID=nobody CLAUDE_CONFIG_DIR="$T/cfg" "$SG" "$P" 10
  rc_is 0 "내 세션만 있으면 0" env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID=s1 CLAUDE_CONFIG_DIR="$T/cfg" "$SG" "$P" 10
  # Claude Code 가 실제로 넣어 주는 이름은 CLAUDE_CODE_SESSION_ID 다. 이걸 안 읽으면 자기 세션을 남의 것으로 센다.
  rc_is 0 "Claude Code 의 세션 변수로도 내 세션을 뺀다" env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID=s1 CLAUDE_CONFIG_DIR="$T/cfg" "$SG" "$P" 10
  rc_is 2 "기록 폴더가 없으면 확인 불가(2)" env CLAUDE_CONFIG_DIR="$T/cfg" "$SG" "$T" 10
  rm -r "$T"
else
  skip "python3 가 없어 session-guard 7건"
fi

echo "== self-update 훅 JSON"
# SessionStart 훅의 평문은 사용자 화면에 안 뜬다. 훅이 부르면 알림을 systemMessage·additionalContext JSON 하나로 내야 한다.
# 되읽기는 스크립트와 따로 python json 으로 한다. 같은 이스케이프로 되읽으면 같이 틀려도 통과한다.
SU="$REPO/shared/scripts/self-update.sh"
if command -v python3 >/dev/null 2>&1; then
  T=$(mktemp -d)
  git init -q -b main "$T/r" && git -C "$T/r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a
  git -C "$T/r" update-ref refs/remotes/origin/main HEAD
  mkdir -p "$T/cfg"
  printf 'mode=link\nrepo=%s\nscope=global\n' "$T/r" > "$T/cfg/.jolla-skills.manifest"
  date +%s > "$T/cfg/.jolla-skills.lastcheck"
  msg=$(printf '한글 "따옴표" 역\\슬래시 탭\t벨\a ESC\033[0m\n둘째 줄')
  printf '%s\n' "$msg" > "$T/cfg/.jolla-skills.pending"
  out=$(CLAUDE_PROJECT_DIR="$T" "$SU" --quiet "$T/cfg" </dev/null)
  if M="$msg" python3 -c '
import json, os, sys
d = json.loads(sys.stdin.read())
m = os.environ["M"]
ok = d["systemMessage"] == m and d["hookSpecificOutput"] == {"hookEventName": "SessionStart", "additionalContext": m}
sys.exit(0 if ok else 1)' <<<"$out" 2>/dev/null; then ok; else bad "훅 JSON 이 알림 원문과 다르다: $out"; fi
  out=$(CLAUDE_PROJECT_DIR="$T" "$SU" --quiet "$T/cfg" </dev/null)
  [ -z "$out" ] && ok || bad "최신이고 알릴 것이 없으면 아무것도 안 내야 하는데: $out"
  printf '%s\n' "$msg" > "$T/cfg/.jolla-skills.pending"
  out=$(env -u CLAUDE_PROJECT_DIR "$SU" --quiet "$T/cfg" </dev/null)
  [ "$out" = "$msg" ] && ok || bad "훅 밖의 --quiet 는 평문이어야 하는데: $out"

  # 훅 명령은 install.sh 의 hook_cmd 그대로 돌린다. 훅 출력은 JSON 하나여야 Claude Code 가 읽는다.
  eval "$(sed -n '/^hook_cmd() {/,/^}/p' "$REPO/install.sh")"
  hook_json() { # <파이썬 식: d 는 읽은 JSON, m 은 systemMessage, M 은 환경 변수 M>  표준 입력이 훅 출력
    M="${M:-}" python3 -c '
import json, os, sys
d = json.loads(sys.stdin.read())
m = d["systemMessage"]
M = os.environ["M"]
ok = d["hookSpecificOutput"] == {"hookEventName": "SessionStart", "additionalContext": m} and ('"$1"')
sys.exit(0 if ok else 1)' 2>/dev/null
  }
  mkdir -p "$T/cfg/skills"; ln -s "$REPO/shared" "$T/cfg/skills/shared"
  printf 'path=skills/shared\npath=agents/없는.md\n' >> "$T/cfg/.jolla-skills.manifest"
  HC=$(hook_cmd "$T/cfg")
  # 링크 깨짐만: check-install 이 넘기고 self-update 가 JSON 하나로 낸다
  out=$(CLAUDE_PROJECT_DIR="$T" bash -c "$HC" </dev/null)
  printf '%s' "$out" | hook_json 'm.startswith("skills 설치가 깨져 있습니다 (2개 중 1개).\n  agents/없는.md (없어짐)")' \
    && ok || bad "링크 깨짐 알림이 훅 JSON 하나로 안 나옴: $out"
  [ ! -e "$T/cfg/.jolla-skills.broken" ] && ok || bad "넘긴 링크 깨짐 알림이 내고 나서도 남음"
  # 링크 깨짐 + 업데이트: 둘이 JSON 하나로 합쳐진다
  git -C "$T/r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m b
  git -C "$T/r" update-ref refs/remotes/origin/main HEAD
  git -C "$T/r" reset -q --hard HEAD~1
  out=$(CLAUDE_PROJECT_DIR="$T" bash -c "$HC" </dev/null)
  printf '%s' "$out" | hook_json 'm.startswith("skills 설치가 깨져 있습니다") and "\nskills 를 " in m and "업데이트했습니다 (커밋 1개)" in m' \
    && ok || bad "업데이트 알림과 링크 깨짐 알림이 JSON 하나로 안 합쳐짐: $out"
  # self-update.sh 를 부를 수 없으면 check-install 이 스스로 JSON 을 낸다
  mkdir -p "$T/c2"; printf 'mode=link\nrepo=%s\npath=agents/없는.md\n' "$T/r" > "$T/c2/.jolla-skills.manifest"
  out=$(CLAUDE_PROJECT_DIR="$T" "$REPO/shared/scripts/check-install.sh" --quiet "$T/c2" </dev/null)
  printf '%s' "$out" | hook_json 'm.startswith("skills 설치가 깨져 있습니다 (1개 중 1개).")' \
    && ok || bad "self-update 가 없을 때 check-install 이 JSON 을 안 냄: $out"
  [ ! -e "$T/c2/.jolla-skills.broken" ] && ok || bad "self-update 가 없는데 넘김 파일을 남김"
  # self-update.sh 가 생기기 전에 건 훅(check-install 만 부름)이면 넘기지 않고 스스로 낸다
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"S=x/check-install.sh"}]}]}}\n' > "$T/cfg/settings.json"
  out=$(CLAUDE_PROJECT_DIR="$T" "$REPO/shared/scripts/check-install.sh" --quiet "$T/cfg" </dev/null)
  printf '%s' "$out" | hook_json 'm.startswith("skills 설치가 깨져 있습니다 (2개 중 1개).")' \
    && ok || bad "옛 훅(self-update 안 부름)인데 check-install 이 JSON 을 안 냄: $out"
  rm "$T/cfg/settings.json"
  # 검사 스크립트에 못 닿음: hook_cmd 의 대체 출력도 JSON 이고 경로가 그대로 실린다
  P="$T/옮긴 '설정' \\d"
  out=$(CLAUDE_PROJECT_DIR="$T" bash -c "$(hook_cmd "$P")" </dev/null)
  printf '%s' "$out" | M="$P/skills/shared" hook_json '"검사 스크립트에 닿지 못합니다 (" + M + ")" in m' \
    && ok || bad "검사 스크립트에 못 닿을 때 훅 JSON 이 아니거나 경로가 다름: $out"
  # 뒤에서 돈 원격 확인 실패: 다음 세션에 이유가 한 번 뜨고, 이어지는 동안은 안 뜨고, 성공하면 다시 센다
  git -C "$T/r" remote add origin "$T/없는-원격"
  "$SU" --bg-fetch "$T/cfg" >"$T/cfg/.jolla-skills.fetch.log" 2>&1
  out=$(CLAUDE_PROJECT_DIR="$T" "$SU" --quiet "$T/cfg" </dev/null)
  printf '%s' "$out" | hook_json 'm.startswith("skills 원격 확인(git fetch)에 실패했습니다: ") and "없는-원격" in m' \
    && ok || bad "원격 확인 실패 이유가 훅 JSON 으로 안 나옴: $out"
  "$SU" --bg-fetch "$T/cfg" >"$T/cfg/.jolla-skills.fetch.log" 2>&1
  out=$(CLAUDE_PROJECT_DIR="$T" "$SU" --quiet "$T/cfg" </dev/null)
  [ -z "$out" ] && ok || bad "같은 원격 확인 실패를 또 알림: $out"
  git init -q --bare "$T/o.git" && git -C "$T/r" push -q "$T/o.git" HEAD:refs/heads/main
  git -C "$T/r" remote set-url origin "$T/o.git"
  "$SU" --bg-fetch "$T/cfg" >"$T/cfg/.jolla-skills.fetch.log" 2>&1
  [ ! -e "$T/cfg/.jolla-skills.fetchfail" ] && ok || bad "원격 확인이 성공했는데 실패 기록이 남음"
  git -C "$T/r" remote set-url origin "$T/없는-원격"
  "$SU" --bg-fetch "$T/cfg" >"$T/cfg/.jolla-skills.fetch.log" 2>&1
  out=$(CLAUDE_PROJECT_DIR="$T" "$SU" --quiet "$T/cfg" </dev/null)
  printf '%s' "$out" | hook_json 'm.startswith("skills 원격 확인(git fetch)에 실패했습니다: ")' \
    && ok || bad "성공 뒤 다시 실패했는데 안 알림: $out"
  rm -r "$T"
else
  skip "python3 가 없어 self-update 훅 JSON 14건"
fi

echo "== 나머지 스크립트"
rc_is 1 "health-wait 타임아웃은 1" "$S/health-wait.sh" http://127.0.0.1:59999/ 6 2
rc_is 0 "scan-targets 는 항상 0"   "$S/scan-targets.sh" "$REPO"

echo
echo "$((PASS+FAIL))개 중 ${PASS}개 통과, ${FAIL}개 실패, ${SKIP}개 건너뜀"
[ "$FAIL" -eq 0 ]
