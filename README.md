# skills

Claude Code 개인 skill 과 전역 작업 규칙.

## 구성

| 경로 | 설치 위치 | 내용 |
|------|-----------|------|
| `CLAUDE.md` | `~/.claude/CLAUDE.md` (심볼릭 링크) | 모든 프로젝트에 적용되는 작업 규칙 |
| `verify-impl/` | `~/.claude/skills/verify-impl` (심볼릭 링크) | 소스 기능 파악 후 실노드 SSH 또는 로컬 구동으로 실증 검증 |
| `agents/` | `~/.claude/agents/` (파일별 심볼릭 링크) | verify-impl 이 부리는 전문 서브에이전트 8종 |
| `deploy-verify/` | `~/.claude/skills/deploy-verify` | 빌드 → 커밋 → 전송 → 재기동 → 반영 확인 → 실증 |
| `shared/` | `~/.claude/skills/shared` | 동시 세션 감지와 스냅샷. 두 skill 이 같이 쓴다 |
| `hooks/pre-commit` | `.git/hooks/pre-commit` | 시크릿·사설IP·내부명·em dash 커밋 차단 |

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
