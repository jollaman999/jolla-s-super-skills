# session-restore

재부팅하기 전에 도는 Claude Code 세션들을 적어 두고, 재부팅 뒤 **같은 디렉터리, 같은 실행 옵션으로 대화를 이어 엽니다.**
tmux 안에서 돌던 것은 같은 이름의 tmux 세션으로, 그냥 터미널에서 돌던 것은 Claude 세션 이름으로 새 tmux 세션을 만들어 엽니다.

> "재부팅해", "다시 띄워", "세션 다시 열어"

저장도 복원도 할지 먼저 묻습니다.

## 전제

- Linux 와 tmux. Claude Code 가 `~/.claude/sessions/<pid>.json` 에 세션 ID 를 적어 두는 버전이어야 합니다.
- 원격 호스트의 세션은 다루지 않습니다. 다시 열 때는 tmux 가 있어야 합니다.
- 대화는 `claude --resume <세션 ID>` 로 이어 엽니다. 화면 스크롤, 패널 분할, 세션 안에서 돌던 백그라운드 작업은
  되살리지 않습니다.

## 흐름

```
재부팅하려 함
  -> 무엇이 적힐지 보여주고 적어 둘지 묻기   (재부팅 승인과 같은 질문)
  -> snapshot.sh                               ${CLAUDE_CONFIG_DIR:-~/.claude}/session-restore/last.tsv
  -> 재부팅
  -> "다시 띄워"
  -> 무엇을 열지 보여주기
  -> restore.sh                                없는 tmux 세션만 만들고 claude --resume 실행
  -> 패널에서 claude 가 도는지 확인
```

## 스크립트

| 스크립트 | 하는 일 |
|----------|---------|
| `scripts/snapshot.sh [-n]` | tmux 패널마다 아래로 내려가며 Claude 프로세스를 찾고, 남은 `~/.claude/sessions/<pid>.json` 중 살아 있는 Claude 를 tmux 밖 세션으로 더해 세션 ID·디렉터리·실행 옵션을 적는다. `-n` 은 보여주기만 |
| `scripts/restore.sh [-n] [기록 파일]` | 줄마다 같은 이름의 tmux 세션을 만들고 그 안에서 claude 를 `--resume` 으로 실행한다. 이미 있는 이름과 사라진 디렉터리는 건너뛴다. `-n` 은 무엇을 열지만 |

실행 옵션은 원래 프로세스의 명령줄에서 가져오고, `-c`/`--continue`/`--resume`/`--session-id` 만 빼고
`--resume <세션 ID>` 를 붙입니다.
