# skills

Claude Code 개인 skill 과 전역 작업 규칙.

## 구성

| 경로 | 설치 위치 | 내용 |
|------|-----------|------|
| `CLAUDE.md` | `~/.claude/CLAUDE.md` (심볼릭 링크) | 모든 프로젝트에 적용되는 작업 규칙 |
| `verify-impl/` | `~/.claude/skills/verify-impl` (심볼릭 링크) | 소스 기능 파악 후 실노드 SSH 또는 로컬 구동으로 실증 검증 |
| `agents/` | `~/.claude/agents/` (파일별 심볼릭 링크) | verify-impl 이 부리는 전문 서브에이전트 4종 |

## verify-impl 팀 구성

팀장(SKILL.md)은 오케스트레이션과 사람과의 대화만 하고, 탐색·실행·반증은 팀원이 병렬로 한다.

| 팀원 | 담당 | 병렬 |
|------|------|------|
| `verify-inventory` | 기능 인벤토리 | `verify-target-scout` 와 동시 |
| `verify-target-scout` | 접속 대상·프론트 탐색 | `verify-inventory` 와 동시 |
| `verify-host` | 호스트 한 대 전담 검증 | 호스트 수만큼 동시 |
| `verify-refuter` | pass 판정 반증 | pass 항목 수만큼 동시 |

심볼릭 링크라 이 repo 를 고치면 즉시 반영된다.

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
