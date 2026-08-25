#!/usr/bin/env bash
# F 노드: 체크리스트 한 항목을 실행하고 결정적으로 판정한다.
# 모델의 "된 것 같다"를 차단하기 위한 exit-code 게이트.
#
# usage: verify-run.sh <id> <expected_code> <curl_args...>
#   예: verify-run.sh VF-01 201 -X POST "$BASE/api/v1/vm" -H "Authorization: Bearer $TOKEN" -d @spec.json
#
# stdout: {"id":…,"verdict":…,"evidence":…,"cmd":…}  (F 노드가 그대로 수집)
# exit  : 0=pass 1=fail 2=unknown
set -uo pipefail
ID="${1:?id}"; shift
EXPECT="${1:?expected http code}"; shift

BODY=$(mktemp)
CODE=$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 30 "$@" 2>/tmp/vr.err)
RC=$?

# 시크릿 마스킹: Bearer 토큰과 흔한 키 값 형태를 evidence/cmd에서 가린다
mask() { sed -E 's/(Bearer|Basic) +[A-Za-z0-9._~+\/=-]+/\1 ***/g; s/([A-Za-z0-9_-]*(token|secret|password|apikey|api_key)[A-Za-z0-9_-]*"?\s*[:=]\s*"?)[^",} ]+/\1***/gI'; }

MASKED=()
for a in "$@"; do MASKED+=("$(printf '%s' "$a" | mask)"); done
CMD=$(printf '%q ' curl "${MASKED[@]}")
OUT=$(head -c 2000 "$BODY" | mask)
rm -f "$BODY"

jout() { printf '{"id":"%s","verdict":"%s","evidence":%s,"cmd":%s}\n' \
  "$ID" "$1" "$(printf '%s' "$2" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" \
  "$(printf '%s' "$CMD" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"; }

if [ $RC -ne 0 ]; then
  jout unknown "curl failed rc=$RC: $(head -c 200 /tmp/vr.err | mask)"; exit 2
fi
if [ "$CODE" = "$EXPECT" ]; then
  jout pass "http=$CODE body=$OUT"; exit 0
fi
jout fail "http=$CODE (expected $EXPECT) body=$OUT"; exit 1
