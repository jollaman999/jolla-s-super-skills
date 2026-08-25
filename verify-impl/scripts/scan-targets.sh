#!/usr/bin/env bash
# B 노드: repo에서 접속 대상 후보와 프론트엔드 존재를 스캔한다.
# 값(시크릿)은 출력하지 않는다 - 변수명과 위치만 출력한다.
# usage: scan-targets.sh [repo_dir]
set -uo pipefail
ROOT="${1:-.}"
cd "$ROOT" || { echo "no such dir: $ROOT" >&2; exit 2; }

EX='--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=dist --exclude-dir=build --exclude-dir=.next --exclude-dir=target'

echo "=== 0. 기존 기록 ==="
if [ -f .claude/verify-targets.md ]; then
  echo "FOUND .claude/verify-targets.md  -> 이걸 사용하고 재질문하지 말 것"
  cat .claude/verify-targets.md
else
  echo "(없음)"
fi

echo
echo "=== 1. URL / host 후보 ==="
grep -rInE 'https?://[a-zA-Z0-9._-]+(:[0-9]+)?' $EX \
  --include='*.md' --include='*.yml' --include='*.yaml' --include='*.json' \
  --include='*.toml' --include='*.tf' --include='*.env*' --include='Makefile' . 2>/dev/null \
  | grep -viE 'schema|xmlns|w3\.org|spdx|license|badge|shields\.io|github\.com/[^ ]*\.git' \
  | head -40

echo
echo "=== 2. 포트 노출 ==="
grep -rInE '^\s*-?\s*"?[0-9]{2,5}:[0-9]{2,5}"?|ports?:|EXPOSE |listen\s*[:=]|PORT\s*[:=]' $EX \
  --include='docker-compose*' --include='*.yml' --include='*.yaml' --include='Dockerfile*' \
  --include='*.env*' --include='*.toml' . 2>/dev/null | head -30

echo
echo "=== 3. 인증 관련 env 변수명 (값 아님) ==="
grep -rhoIE '\b[A-Z][A-Z0-9_]{2,}(TOKEN|SECRET|KEY|PASSWORD|PASSWD|AUTH|CRED|APIKEY|API_KEY)[A-Z0-9_]*\b' $EX . 2>/dev/null \
  | sort -u | head -40

echo
echo "=== 4. API 스펙 ==="
find . -maxdepth 4 \( -iname 'openapi*' -o -iname 'swagger*' -o -iname '*.proto' -o -iname 'schema.graphql' \) \
  -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | head -20

echo
echo "=== 5. 실행 방법 힌트 ==="
for f in Makefile Taskfile.yml justfile docker-compose.yml docker-compose.yaml; do
  [ -f "$f" ] && echo "--- $f" && head -40 "$f"
done
ls .github/workflows/*.y*ml 2>/dev/null | head -10

echo
echo "=== 6. 프론트엔드 존재 판정 ==="
FE=no
if [ -f package.json ] && grep -qE '"(react|vue|svelte|next|nuxt|@angular/core|solid-js)"' package.json 2>/dev/null; then
  FE=yes; echo "package.json: 프론트 프레임워크 의존 발견"
fi
for d in web frontend ui console client app/frontend; do
  [ -d "$d" ] && { FE=yes; echo "디렉터리: $d"; }
done
find . -maxdepth 3 -name package.json -not -path './node_modules/*' 2>/dev/null | head -10
echo "FRONTEND=$FE"

echo
echo "=== 7. 최근 변경 (심층 대상 후보) ==="
git log --since='30 days ago' --name-only --pretty=format: 2>/dev/null \
  | grep -vE '^$|node_modules' | sort | uniq -c | sort -rn | head -20

# 정보 수집용 스크립트 - 게이트가 아니므로 항상 0으로 끝낸다
exit 0
