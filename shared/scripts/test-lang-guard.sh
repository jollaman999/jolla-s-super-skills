#!/usr/bin/env bash
# lang-guard.py 의 판정을 시험한다. 세션을 안 띄우므로 1초 안에 끝난다.
#
# 진행 줄은 지난 세션에서 실제로 새어 나간 글의 모양을 그대로 쓴다.
# 기록 파일은 판정에 쓰는 줄(사용자 발화, 도구 앞 글)만 남긴 최소 모양이다.
#
# usage: shared/scripts/test-lang-guard.sh
# exit: 0=전부 통과  1=실패 있음  2=python 없음
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
G="$HERE/lang-guard.py"
# 이름만 보고 고르지 않는다. Windows 에는 실행하면 rc=49 로 끝나는 Store 가짜 python3 가 PATH 앞에 있을 수 있다.
PY=""
for _c in python3 python py; do
  command -v "$_c" >/dev/null 2>&1 && "$_c" -c 'import sys' >/dev/null 2>&1 && { PY="$_c"; break; }
done
[ -n "$PY" ] || { echo "python 이 없습니다"; exit 2; }

TMPD=$("$PY" -c 'import tempfile; print(tempfile.gettempdir())')
WORK=$(mktemp -d)
SIDS=()
PASS=0; FAIL=0

# run <세션id> <사용자 발화 또는 빈 문자열> <도구 앞 글>   -> 훅 출력
run() {
  local sid="$1" user="$2" text="$3" tr="$WORK/$1.jsonl"
  "$PY" - "$tr" "$user" "$text" <<'PY'
import json, sys
path, user, text = sys.argv[1:4]
rows = []
if user:
    rows.append({"type": "user", "message": {"content": user}})
else:
    # 사용자 발화가 기록 끝에 없는 경우: 앞 도구의 결과만 있다
    rows.append({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t0", "content": "ok"}]}})
rows.append({"type": "assistant", "message": {"content": [{"type": "text", "text": text},
                                                         {"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]}})
with open(path, "w") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
  "$PY" -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "session_id": sys.argv[2], "tool_use_id": "t1"}))' \
    "$tr" "$sid" | "$PY" "$G"
}

# chk <warn|quiet> <설명> <사용자 발화> <도구 앞 글> [세션id]
N=0
chk() {
  local want="$1" what="$2" user="$3" text="$4" sid="${5:-}" out got
  N=$((N+1))
  [ -n "$sid" ] || sid="lgtest$$n$N"
  SIDS+=("$sid")
  out=$(run "$sid" "$user" "$text")
  if printf '%s' "$out" | grep -q 'lang-guard'; then got=warn; else got=quiet; fi
  if [ "$got" = "$want" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); printf '  실패  %s: %s 여야 하는데 %s\n' "$what" "$want" "$got"; fi
}

echo "== 알려야 하는 것"
chk warn "낱자로만 답한 뒤 영어 진행 줄" "ㄱㄱ" "Now update memory."
chk warn "ㅇㅇ 뒤 영어 진행 줄" "ㅇㅇ" "Build OK. Deploying to the node now."
chk warn "두 단어 영어 진행 줄" "설치 계속 진행해줘" "Still installing."
chk warn "괄호 안만 한국어" "기다려 줘" "Still waiting for the build (20분 상한)"
chk warn "세 단어 영어 진행 줄" "로그 봐줘" "Now reading logs."
# 같은 세션에서 앞서 한국어 발화를 봤고, 지금은 사용자 발화가 기록 끝에 없다 (긴 작업 중)
chk quiet "언어 기록용 앞 호출" "로그 봐줘" "로그를 봅니다." "lgtest$$keep"
chk warn "사용자 발화가 기록 끝에 없어도 세션의 언어로 판정" "" "Checking the pod status again." "lgtest$$keep"

echo "== 넘겨야 하는 것"
chk quiet "한국어 진행 줄" "ㄱㄱ" "메모리를 고칩니다."
chk quiet "한국어 안 괄호의 영어" "빌드해줘" "빌드 (go build) 성공했습니다."
chk quiet "한 단어" "ㄱ" "Done."
chk quiet "코드만" "테스트 돌려" '`make test`'
chk quiet "사용자가 영어로 씀" "go ahead" "Now update memory."
chk quiet "세션 언어 기록이 없고 사용자 발화도 없음" "" "Checking the pod status again."

for s in "${SIDS[@]}"; do
  rm -f "$WORK/$s.jsonl" "$TMPD/lang-guard-$s" "$TMPD/lang-guard-$s.lang"
done
rmdir "$WORK"

echo
echo "통과 $PASS, 실패 $FAIL"
[ "$FAIL" -eq 0 ]
