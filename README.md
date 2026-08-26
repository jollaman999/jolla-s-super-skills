# skills

Claude Code 개인 skill 과 전역 작업 규칙.

## 구성

| 경로 | 설치 위치 | 내용 |
|------|-----------|------|
| `CLAUDE.md` | `~/.claude/CLAUDE.md` (심볼릭 링크) | 모든 프로젝트에 적용되는 작업 규칙 |
| `verify-impl/` | `~/.claude/skills/verify-impl` (심볼릭 링크) | 소스 기능 파악 후 실노드 SSH 또는 로컬 구동으로 실증 검증 |
| `agents/` | `~/.claude/agents/` (파일별 심볼릭 링크) | verify-impl 이 부리는 전문 서브에이전트 8종 |
| `deploy-verify/` | `~/.claude/skills/deploy-verify` | 빌드 → 커밋 → 전송 → 재기동 → 반영 확인 → 실증 |
| `shared/` | `~/.claude/skills/shared` | 동시 세션 감지, 스냅샷, repo 스타일 프로파일링 |
| `hooks/` | 각 repo `.git/hooks/` | 시크릿 커밋 차단 + 커밋 메시지 규칙. 기존 훅 체인 보존 |

## verify-impl 팀 구성

팀장(SKILL.md)은 경로 판정, 사람과의 대화, 판단, 종합만 하고 탐색·실행·반증·진단은 팀원 8명이 병렬로 한다.

| 팀원 | 담당 노드 | 병렬 단위 |
|------|-----------|-----------|
| `verify-inventory` | A 기능 인벤토리 | ★1 |
| `verify-target-scout` | B 접속 대상·프론트 탐색 | ★1 |
| `verify-crosscheck` | X 구현↔스펙 대조 | ★1.5 (C와 동시) |
| `verify-host` | F 호스트 전담 검증 | ★2 호스트 수만큼 |
| `verify-frontend` | F 프론트↔백엔드 연계 | ★2 |
| `verify-refuter` | F′ pass 판정 반증 | ★3 pass 수만큼 |
| `verify-diagnoser` | H fail 원인 추적 | ★4 fail 수만큼 |
| `verify-differ` | H 호스트 간 차이 원인 | ★4 갈린 항목 수만큼 |

### 경로 판정

세션 3,240건 측정 결과 프롬프트 중앙값이 40자이고 65%가 60자 미만이다.
짧은 단발 확인에 풀코스를 돌리지 않도록 P 노드가 `light` / `full` 을 판정한다. 기준 → `verify-impl/references/routing.md`

### 동시 세션

한 프로젝트에 Claude 세션이 여러 개 붙는 일이 실제로 잦다. `shared/scripts/session-guard.sh` 로 확인하고,
있으면 `snapshot.sh` 로 떠서 분석한 뒤 적용 직전에 드리프트를 확인한다.

### 진단과 루프

fail 은 보고로 끝나지 않고 H 에서 원인까지 추적한다. **진단만 하고 고치지는 않는다.**
사용자가 수정한 뒤에는 R 이 실패 항목만 재검증한다 (배포 반영 확인 후, 상한 3회).

## repo 프로필

`CLAUDE.md` 는 "그 repo 에서 처음 커밋하기 전에 스타일을 분석하고 물어본다" 를 요구한다.
매번 손으로 하지 않도록 스크립트로 뽑는다.

```sh
shared/scripts/repo-profile.sh <repo>          # 표만 보기
shared/scripts/repo-profile.sh <repo> --save   # 승인 후 .claude/repo-profile.md 에 기록
```

내는 것: 언어, 접두사 체계(conventional / 스코프형 / 없음), 다중 스코프 형태, 제목 길이 중앙값·p90,
본문 비율, Signed-off-by, 머지 커밋 유무, 티켓번호, 코드 인덴트, 행 길이, 주석 언어.

Revert/Merge 는 자동 생성 제목이라 통계에서 뺀다. 내 커밋이 20개 이상이면 내 것만 보고,
적으면 repo 전체를 보면서 그렇다고 밝힌다. 코드 표본은 **그 사람이 최근에 만진 파일**에서 고른다.

`.claude/repo-profile.md` 가 있으면 다시 묻지 않는다.

## 커밋 훅

```sh
hooks/install-hooks.sh <repo>            # gh 로 공개 여부를 보고 프로필 자동 결정
hooks/install-hooks.sh <repo> private    # 명시 지정
```

`pre-commit` 과 `commit-msg` 둘 다 설치된다.

| 훅 | 검사 | 프로필 |
|----|------|--------|
| `pre-commit` | 비밀번호·토큰·개인키 | 항상 |
| `pre-commit` | 내부 조직명, 사설/공인 IP | `public` 만 |
| `pre-commit` | em dash | 항상 |
| `pre-commit` | `.claude/verify-targets.md` 등 접속 대상 파일 | 항상 |
| `commit-msg` | Co-Authored-By, AI 생성 문구, em dash, 제목 뒤 `-` 부연, 본문 앞 빈 줄 | 항상 |

사내 repo 에서는 내부 조직명과 사설 IP 가 정상 내용이므로 `private` 이 기본이다.
**em dash 와 커밋 메시지 규칙은 시크릿이 아니라 표기 규칙이므로 프로필을 안 가린다.**

본문 자체는 막지 않는다. 부연이 필요하면 제목 다음 빈 줄 뒤에 쓴다.
`Revert "..."` / `Merge ...` / `fixup!` 제목은 남의 커밋 제목을 인용하는 것이라 제목 규칙에서 뺀다.

기존 훅이 있으면 `<훅이름>.orig` 로 옮겨 체인하므로 husky 같은 것이 안 깨진다.
프로필은 `.git/hooks/.profile` 에 적히고 훅은 그 값을 읽는다.

## 새 머신에 설치

```sh
git clone <this-repo> ~/ai/skills
mkdir -p ~/.claude/skills
ln -sfn ~/ai/skills/CLAUDE.md ~/.claude/CLAUDE.md
ln -sfn ~/ai/skills/verify-impl ~/.claude/skills/verify-impl
mkdir -p ~/.claude/agents
for f in ~/ai/skills/agents/*.md; do ln -sfn "$f" ~/.claude/agents/$(basename $f); done
```

## 규칙

- 실제 호스트·비밀번호·토큰을 커밋하지 않는다. 문서 예시는 RFC1918 / TEST-NET 대역을 쓴다.
- 프로젝트별 접속 대상은 각 프로젝트의 `.claude/verify-targets.md` 에 두고 여기 커밋하지 않는다.

## 검증

```sh
verify-impl/evals/cases.md   # 평가 케이스 + 스크립트 회귀
```
