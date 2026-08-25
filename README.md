# skills

Claude Code 개인 skill 과 전역 작업 규칙.

## 구성

| 경로 | 설치 위치 | 내용 |
|------|-----------|------|
| `CLAUDE.md` | `~/.claude/CLAUDE.md` (심볼릭 링크) | 모든 프로젝트에 적용되는 작업 규칙 |
| `verify-impl/` | `~/.claude/skills/verify-impl` (심볼릭 링크) | 소스 기능 파악 후 실노드 SSH 또는 로컬 구동으로 실증 검증 |

심볼릭 링크라 이 repo 를 고치면 즉시 반영된다.

## 새 머신에 설치

```sh
git clone <this-repo> ~/ai/skills
mkdir -p ~/.claude/skills
ln -sfn ~/ai/skills/CLAUDE.md ~/.claude/CLAUDE.md
ln -sfn ~/ai/skills/verify-impl ~/.claude/skills/verify-impl
```

## 규칙

- 실제 호스트·비밀번호·토큰을 커밋하지 않는다. 문서 예시는 RFC1918 / TEST-NET 대역을 쓴다.
- 프로젝트별 접속 대상은 각 프로젝트의 `.claude/verify-targets.md` 에 두고 여기 커밋하지 않는다.

## 검증

```sh
verify-impl/evals/cases.md   # 평가 케이스 + 스크립트 회귀
```
