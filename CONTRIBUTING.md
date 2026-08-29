# 이 repo 를 고칠 때

설치해서 쓰는 데는 필요 없는 내용입니다. 여기 문서와 스크립트를 고치는 사람을 위한 것입니다.

## 경로 쓰는 법

문서에 경로를 쓸 때 두 가지가 섞입니다. **읽으라고 가리키는 경로**와 **그대로 복사해 실행할 명령**입니다.
이 둘은 기준이 다릅니다.

| 무엇 | 어떻게 | 예 |
|------|--------|-----|
| 다른 문서를 가리킬 때 | skill 폴더 기준 상대경로 | `verify-impl/SKILL.md` 안에서 `references/ssh.md` |
| 실행할 명령을 적을 때 | `~/.claude/skills/...` 절대경로 | `~/.claude/skills/verify-impl/scripts/ssh-run.sh` |

명령을 상대경로로 적으면 안 되는 이유가 있습니다. 그 명령이 실행되는 곳은 **사용자의 프로젝트
디렉터리**이지 skill 폴더가 아닙니다. `~/git/myapp` 에서 작업하다가 `scripts/ssh-run.sh` 를 실행하면
`~/git/myapp/scripts/ssh-run.sh` 를 찾다가 실패합니다.

```sh
scripts/ssh-run.sh VF-01 '...'                             # 안 됩니다
~/.claude/skills/verify-impl/scripts/ssh-run.sh VF-01 '...' # 이렇게
```

클론 위치(`~/ai/skills` 같은 것)는 어느 문서에도 넣지 않습니다. 사람마다 다르기 때문입니다.
설치하면 `~/.claude/skills/` 아래로 링크가 걸리므로 그 경로를 씁니다.

## 문서를 고친 뒤

- 스크립트를 고쳤으면 `bash -n <파일>` 로 문법을 보고, 회귀는 `verify-impl/evals/cases.md` 의 케이스로 돌립니다.
- 제목에 개수를 적지 않습니다 (`네 가지`, `5필드`). 항목이 늘면 어긋납니다.
- 커밋 전에 `./install.sh --check` 로 이 환경에서 실행되는지 봅니다.
- 커밋 메시지 규칙과 표기 규칙은 커밋 훅이 검사합니다 (`hooks/README.md`)
