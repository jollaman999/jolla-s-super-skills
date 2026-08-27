#!/usr/bin/env bash
# F 노드: 체크리스트 한 항목을 실행하고 결정적으로 판정한다.
# 모델의 "된 것 같다"를 차단하기 위한 exit-code 게이트.
#
# usage: verify-run.sh <id> <expected_code> <curl_args...>
#   예: verify-run.sh VF-01 201 -X POST "$BASE/api/v1/vm" -H "Authorization: Bearer $TOKEN" -d @spec.json
#
# stdout: {"id":…,"verdict":…,"evidence":…,"cmd":…}  (F 노드가 그대로 수집)
# exit  : 0=pass 1=fail 2=unknown
#
# 이식성: 외부 의존은 curl 과 awk 뿐이다. python 은 쓰지 않는다.
set -uo pipefail
ID="${1:?id}"; shift
EXPECT="${1:?expected http code}"; shift

have() { command -v "$1" >/dev/null 2>&1; }

# 시크릿 마스킹: Bearer 토큰과 흔한 키 값 형태를 evidence/cmd에서 가린다
mask() { sed -E 's/(Bearer|Basic) +[A-Za-z0-9._~+\/=-]+/\1 ***/g; s/([A-Za-z0-9_-]*(token|secret|password|apikey|api_key)[A-Za-z0-9_-]*"?\s*[:=]\s*"?)[^",} ]+/\1***/gI'; }

# JSON 문자열 인코딩. python/jq 없이 awk 만 쓴다 - Windows Git Bash 에는 python3 가 없다.
# 예전에는 python3 가 없으면 값이 빈 문자열이 되어 JSON 이 깨진 채로 나갔다.
json_str() {
  awk '{ gsub(/\\/,"\\\\"); gsub(/"/,"\\\"");
         gsub(/\t/,"\\t"); gsub(/\r/,"\\r");
         gsub(/[\001-\010\013\014\016-\037\177]/,"");
         out = out (NR>1 ? "\\n" : "") $0 }
       END { printf "\"%s\"", out }'
}

MASKED=()
for a in "$@"; do MASKED+=("$(printf '%s' "$a" | mask)"); done
CMD=$(printf '%q ' curl "${MASKED[@]}")

jout() { printf '{"id":"%s","verdict":"%s","evidence":%s,"cmd":%s}\n' \
  "$ID" "$1" "$(printf '%s' "$2" | json_str)" "$(printf '%s' "$CMD" | json_str)"; }

if ! have curl; then
  # 도구가 없는 것은 구현 실패가 아니다. fail 이 아니라 unknown 이다.
  jout unknown "curl 이 없습니다. Windows 는 Git for Windows 또는 Windows 10 1803+ 내장 curl 이 필요합니다"
  exit 2
fi

# /tmp 하드코딩은 동시 실행 시 서로 덮어쓴다. TMPDIR 을 따르는 임시 파일을 쓴다.
BODY=$(mktemp "${TMPDIR:-/tmp}/vr-body-XXXXXX") || { jout unknown "임시 파일을 만들 수 없습니다"; exit 2; }
ERR=$(mktemp "${TMPDIR:-/tmp}/vr-err-XXXXXX")   || { rm -f "$BODY"; jout unknown "임시 파일을 만들 수 없습니다"; exit 2; }
trap 'rm -f "$BODY" "$ERR"' EXIT

CODE=$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 30 "$@" 2>"$ERR")
RC=$?

OUT=$(head -c 2000 "$BODY" | mask)

if [ $RC -ne 0 ]; then
  jout unknown "curl failed rc=$RC: $(head -c 200 "$ERR" | mask)"; exit 2
fi
if [ "$CODE" = "$EXPECT" ]; then
  jout pass "http=$CODE body=$OUT"; exit 0
fi
jout fail "http=$CODE (expected $EXPECT) body=$OUT"; exit 1
