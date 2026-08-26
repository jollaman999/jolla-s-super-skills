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
echo "=== 3. env 변수명 (값 아님) ==="
# 대문자 식별자를 통째로 긁으면 TS/JS 프로젝트에서 ALARM_TAB_KEY_MAP 같은 상수가 쏟아진다.
# env 파일의 좌변과 실제 env 접근 패턴만 본다.
{
  # (a) .env 계열 파일의 변수명 (= 좌변만)
  for f in $(find . -maxdepth 3 -name '.env' -o -maxdepth 3 -name '.env.*' -o -maxdepth 3 -name '*.env' 2>/dev/null | grep -vE 'node_modules|/\.git/' | head -20); do
    grep -hoE '^[[:space:]]*(export[[:space:]]+)?[A-Z][A-Z0-9_]*(?==)' "$f" 2>/dev/null \
      || grep -hoE '^[[:space:]]*(export[[:space:]]+)?[A-Z][A-Z0-9_]*=' "$f" 2>/dev/null | tr -d '= '
  done
  # (b) 코드에서의 env 접근
  grep -rhoIE 'process\.env\.[A-Z][A-Z0-9_]*' $EX . 2>/dev/null | sed 's/.*\.//'
  grep -rhoIE 'import\.meta\.env\.[A-Z][A-Z0-9_]*' $EX . 2>/dev/null | sed 's/.*\.//'
  grep -rhoIE '(os\.Getenv|System\.getenv|getenv)\(["'"'"']([A-Z][A-Z0-9_]*)' $EX . 2>/dev/null | sed -E 's/.*["'"'"']//'
  grep -rhoIE '\$\{?[A-Z][A-Z0-9_]{3,}\}?' $EX --include='docker-compose*' --include='*.yml' --include='*.yaml' --include='Dockerfile*' . 2>/dev/null | tr -d '${}'
} 2>/dev/null | grep -vE '^(PATH|HOME|USER|SHELL|PWD|LANG|TERM|NODE_ENV|CI)$' | sort -u | head -40

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
