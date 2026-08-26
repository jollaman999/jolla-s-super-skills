<div align="center">

# skills

**Claude Code 가 내 방식대로 일하게 만드는 규칙, skill, 훅 모음**

작업 규칙 · 실증 검증 팀 · 배포 체인 · 커밋 훅 · repo 스타일 프로파일러

<sub>클론 위치는 어디든 상관없다. `./install.sh` 하나로 `~/.claude` 에 걸린다.</sub>

</div>

---

## 이게 뭔가

기본 상태의 Claude Code 는 매번 다르게 일한다. 확인 안 한 걸 단정하고, 범위 밖을 고치고,
repo 마다 다른 커밋 스타일을 무시하고, "에러 없음" 을 통과로 보고한다.

이 repo 는 그 네 가지를 각각 다른 층위에서 막는다.

| 층위 | 무엇 | 강제 방식 |
|------|------|-----------|
| **규칙** | 추정 금지, 범위 준수, 응답 형식, 판단 기준 | `CLAUDE.md` 가 모든 세션에 항상 로드된다 |
| **절차** | 실증 검증, 배포 반영 확인 | skill 이 게이트를 걸어 승인 없이 못 넘어가게 한다 |
| **차단** | 시크릿 유출, 커밋 메시지 규칙 | git 훅이 커밋 자체를 막는다 |
| **근거** | repo 별 커밋·코드 스타일 | 스크립트가 로그에서 뽑아 표로 낸다 |

문서에만 적힌 규칙은 세션이 바뀌면 지켜지기도 하고 안 지켜지기도 한다.
그래서 **훅이나 스크립트로 막을 수 있는 것은 문서에 맡기지 않는다.**

## 빠른 시작

```sh
git clone <this-repo> ~/ai/skills   # 위치는 자유
cd ~/ai/skills
./install.sh
```

`~/.claude` 아래에 심볼릭 링크를 건다. **repo 를 `git pull` 하면 바로 반영된다.**

```
~/.claude/CLAUDE.md              -> CLAUDE.md
~/.claude/skills/verify-impl     -> verify-impl/
~/.claude/skills/deploy-verify   -> deploy-verify/
~/.claude/skills/shared          -> shared/
~/.claude/skills/hooks           -> hooks/
~/.claude/agents/verify-*.md     -> agents/*.md   (8개)
```

| 옵션 | 하는 일 |
|------|---------|
| `./install.sh` | 링크를 건다. 링크가 아닌 파일이 이미 있으면 **건드리지 않고 중단**한다 |
| `./install.sh --dry-run` | 무엇을 할지만 출력한다 |
| `./install.sh --force` | 기존 것을 `<이름>.bak.<날짜>` 로 옮기고 덮어쓴다 |
| `./install.sh --uninstall` | 이 repo 가 건 링크만 지운다. 남의 파일은 안 건드린다 |

설치 위치를 바꾸려면 `CLAUDE_HOME=/다른/경로 ./install.sh`.

---

## 구성

| 경로 | 내용 |
|------|------|
| [`CLAUDE.md`](CLAUDE.md) | 모든 프로젝트에 적용되는 작업 규칙 |
| [`verify-impl/`](verify-impl/SKILL.md) | 실노드 SSH 또는 로컬 구동으로 구현을 실증 검증 |
| [`deploy-verify/`](deploy-verify/SKILL.md) | 빌드 → 커밋 → 전송 → 재기동 → 반영 확인 → 실증 |
| [`agents/`](agents/) | verify-impl 이 부리는 전문 서브에이전트 8종 |
| [`shared/`](shared/) | 동시 세션 감지, 스냅샷, repo 스타일 프로파일러 |
| [`hooks/`](hooks/) | 시크릿 커밋 차단 + 커밋 메시지 규칙 |
| [`install.sh`](install.sh) | 위를 `~/.claude` 에 링크 |

**경로 표기 규칙**: 문서끼리의 참조는 skill 폴더 기준 상대경로(`references/ssh.md`, `../shared/references/...`)로 쓴다.
repo 에서 읽어도 설치 후에 읽어도 같은 곳을 가리킨다.
**실행되는 명령**은 절대경로(`~/.claude/skills/...`)로 쓴다. 실행 시 cwd 는 사용자 프로젝트이지 skill 폴더가 아니다.
클론 위치(`~/ai/skills`)는 어느 문서에도 넣지 않는다.

---

## verify-impl - 실증 검증

> "검증해줘", "제대로 동작하는지 확인", "왜 안되는지 확인"

**"에러가 없다" 는 pass 가 아니다.** 이 계열 코드베이스의 지배적 실패 양식은 예외가 아니라
조용히 틀린 값을 내는 무음 실패다. 기대한 동작의 흔적이 관측돼야 pass 로 친다.

팀장(SKILL.md)은 **경로 판정, 사람과의 대화, 판단, 종합만** 한다.
탐색·실행·반증·진단은 팀원 8명이 병렬로 한다. 로그 수천 줄이 팀원 컨텍스트에서 끝나고 팀장에겐 JSON 만 온다.

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

**경로 판정** - 세션 3,240건 측정 결과 프롬프트 중앙값이 40자이고 65%가 60자 미만이다.
짧은 단발 확인에 풀코스를 돌리지 않도록 P 노드가 `light` / `full` 을 가른다. → [`routing.md`](verify-impl/references/routing.md)

**반증** - pass 가 나오면 끝이 아니다. `verify-refuter` 가 항목마다 붙어 그 판정을 깨려고 시도한다.
반증에 실패해야 최종 pass 다. 확증 편향을 깨려고 팀장과 컨텍스트를 분리한다.

**진단과 루프** - fail 은 보고로 끝나지 않고 H 에서 원인까지 추적한다. **진단만 하고 고치지는 않는다.**
사용자가 수정한 뒤에는 R 이 실패 항목만 재검증한다 (배포 반영 확인 후, 상한 3회).

## deploy-verify - 배포와 반영 확인

> "배포해줘", "이미지 복사해서 로드하고 재기동", "빌드해서 올려"

**전송했다는 것과 그게 돌고 있다는 것은 다른 주장이다.** 반영 확인 없이 "배포 완료" 라고 하지 않는다.

빌드 → 커밋·태그·push 승인 → 전송 → 로드·재기동 승인 → 헬스 대기 → **반영 확인**(md5/이미지태그) → 실증.
되돌리기 어려운 단계마다 블로킹 게이트가 있고, **롤백 방법을 모르면 시작하지 않는다.**

실증은 `verify-impl` 로 넘긴다. 이 skill 이 반영시키고 저쪽이 검증한다.

## 동시 세션

한 프로젝트에 Claude 세션이 여러 개 붙는 일이 실제로 잦다.
2026-07-16 에 `stash` → 테스트 → `pop` 이 충돌해 **미커밋 작업 20개 파일이 워킹트리에서 사라진 사고**가 있었다.
그래서 `git stash` 를 무조건 쓰지 않는다.

```sh
~/.claude/skills/shared/scripts/session-guard.sh <repo> 10   # 다른 세션이 붙어 있나
~/.claude/skills/shared/scripts/snapshot.sh take <repo>      # 원본 대신 스냅샷에서 분석
~/.claude/skills/shared/scripts/snapshot.sh drift <snap>     # 적용 직전 드리프트 확인
```

→ [`concurrent-sessions.md`](shared/references/concurrent-sessions.md)

---

## repo 프로필

`CLAUDE.md` 는 "그 repo 에서 처음 커밋하기 전에 스타일을 분석하고 물어본다" 를 요구한다.
매번 손으로 하지 않도록 스크립트로 뽑는다.

```sh
~/.claude/skills/shared/scripts/repo-profile.sh <repo>          # 표만 보기
~/.claude/skills/shared/scripts/repo-profile.sh <repo> --save   # 승인 후 .claude/repo-profile.md 에 기록
```

내는 것: 언어(한글/영어), 접두사 체계(conventional / 스코프형 / 없음), 다중 스코프 형태,
제목 길이 중앙값·p90, 본문 비율, Signed-off-by, 머지 커밋 유무, 티켓번호,
그리고 코드 인덴트·행 길이·주석 언어.

Revert/Merge 는 자동 생성 제목이라 통계에서 뺀다. 내 커밋이 20개 이상이면 내 것만 보고,
적으면 repo 전체를 보면서 그렇다고 밝힌다. 코드 표본은 **그 사람이 최근에 만진 파일**에서 고른다.

`.claude/repo-profile.md` 가 있으면 다시 묻지 않는다.

repo 마다 실제로 갈린다. 같은 사람이 쓴 안드로이드 커널 repo 는 영어 + `모듈명: Verb ...` + 제목 중앙값 44자이고,
업무 repo 는 한글 + `fix:`/`feat:` + 중앙값 38자다. 하나로 뭉뚱그리면 둘 다 틀린다.

## 커밋 훅

```sh
~/.claude/skills/hooks/install-hooks.sh <repo>            # gh 로 공개 여부를 보고 프로필 자동 결정
~/.claude/skills/hooks/install-hooks.sh <repo> private    # 명시 지정
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
우회가 정말 필요하면 `git commit --no-verify`.

---

## 이 repo 에 기여할 때

- 실제 호스트·비밀번호·토큰을 커밋하지 않는다. 문서 예시는 RFC1918 / TEST-NET 대역을 쓴다.
- 프로젝트별 접속 대상은 각 프로젝트의 `.claude/verify-targets.md` 에 두고 여기 커밋하지 않는다.
- 클론 위치를 문서에 하드코딩하지 않는다. 위 **경로 표기 규칙**을 따른다.
- 개수처럼 변하는 수치를 규칙에 박지 않는다.

```sh
verify-impl/evals/cases.md   # 평가 케이스 + 스크립트 회귀
```
