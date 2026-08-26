# shared

`verify-impl` 과 `deploy-verify` 가 함께 쓰는 스크립트입니다. 단독으로 써도 됩니다.

## repo-profile.sh

**그 repo 의 커밋 스타일과 코드 스타일을 로그에서 뽑아 표로 냅니다.**

```sh
~/.claude/skills/shared/scripts/repo-profile.sh <repo>          # 표만 보기
~/.claude/skills/shared/scripts/repo-profile.sh <repo> --save   # .claude/repo-profile.md 에 기록
```

repo 마다 커밋 스타일은 실제로 갈립니다.
같은 사람이 쓴 안드로이드 커널 repo 는 영어에 `모듈명: Verb ...` 형태이고 제목 중앙값이 44자인데,
업무 repo 는 한글에 `fix:`/`feat:` 이고 중앙값이 38자입니다. 하나로 뭉뚱그리면 둘 다 틀립니다.

그래서 첫 커밋 전에 물어봐야 하는데, 매번 손으로 세는 대신 스크립트로 뽑습니다.
`.claude/repo-profile.md` 가 있으면 다시 묻지 않습니다.

내는 것:

| 갈래 | 항목 |
|------|------|
| 커밋 | 언어, 접두사 체계, 다중 스코프 형태, 제목 길이 중앙값·p90, 본문 비율, Signed-off-by, 머지 커밋, 티켓번호 |
| 코드 | 주력 확장자, 인덴트, 행 길이 분포, 주석 언어, 주석 형태 |

세는 방식에 몇 가지 판단이 들어가 있습니다.

- **Revert 와 Merge 는 통계에서 뺍니다.** 자동 생성 제목이라 본인 스타일이 아닙니다
- 내 커밋이 20개 이상이면 내 것만 보고, 적으면 repo 전체를 보되 그렇다고 밝힙니다
- 코드 표본은 무작위 파일이 아니라 **그 사람이 최근에 만진 파일**에서 고릅니다
- 제목 길이는 바이트가 아니라 글자로 셉니다. 한글이 3배로 부풀지 않게

## session-guard.sh

**같은 프로젝트에 다른 Claude 세션이 붙어 있는지 확인합니다.**

```sh
~/.claude/skills/shared/scripts/session-guard.sh <repo> [분]
```

한 프로젝트에 세션이 여러 개 붙는 일이 실제로 잦습니다.
다른 세션의 커밋 안 된 작업이 워킹트리에 있다고 가정하고 움직여야 합니다.

정보만 모으고 판단은 호출한 쪽이 합니다. 다른 세션이 있으면 exit 1 입니다.

## snapshot.sh

**원본을 오래 붙잡지 않고, 스냅샷을 떠서 그 위에서 분석합니다.**

```sh
~/.claude/skills/shared/scripts/snapshot.sh take  <repo>     # 스냅샷 생성
~/.claude/skills/shared/scripts/snapshot.sh drift <스냅샷>   # 그 사이 바뀐 파일
~/.claude/skills/shared/scripts/snapshot.sh clean <스냅샷>   # 제거
```

분석하는 동안 다른 세션이 파일을 바꿔도 영향받지 않습니다.
패치하기 직전에 `drift` 로 그 사이 원본이 바뀌었는지 확인하고 적용합니다.

`git stash` 대신 이걸 씁니다.
2026-07-16 에 `stash` 후 테스트하고 `pop` 하는 과정에서 충돌이 나
**커밋 안 된 20개 파일이 워킹트리에서 사라진 사고**가 있었습니다. 그 뒤로 `stash` 는 쓰지 않습니다.

자세한 절차는 [`references/concurrent-sessions.md`](references/concurrent-sessions.md) 에 있습니다.
