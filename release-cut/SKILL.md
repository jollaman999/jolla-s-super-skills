---
name: release-cut
description: 태그를 찍고 릴리즈 노트를 쓰고 바이너리를 올린 뒤, 이 릴리즈를 따라가야 할 다른 repo 가 어디인지 보고하는 데까지 간다. 버전 갱신 → 변경 목록 → 릴리즈 노트 승인 → 커밋·태그 → 릴리즈 생성·바이너리 → CD 대기 → 연동 repo 보고 순서로 게이트를 걸어 진행한다. TRIGGER - "릴리즈 찍어줘", "태그 찍고 릴리즈", "vX.Y.Z 로 올려", "릴리즈 때리고 배포해". SKIP - 노드에 반영만 필요할 때(deploy-verify), 커밋·푸시만 할 때.
---

# release-cut

버전 갱신 → 변경 목록 → **릴리즈 노트 승인** → 커밋·태그 → **릴리즈 생성·바이너리** → CD 이미지 대기 → 연동 repo 보고 → 배포.

`deploy-verify` 와 짝이다. 이 skill 이 릴리즈를 만들고, `deploy-verify` 가 노드에 반영한다.
마지막 단계에서 넘긴다.

## 절대 규칙

1. **릴리즈는 승인 대상이다.** 태그를 찍기 전에 묻는다. 되돌리려면 태그 삭제 + force push 가 필요하다.
   > "릴리즈는 **내가 말하면 해**" / "릴리즈는 **제일 나중에** 찍어 지금은 임시로하고"
2. **릴리즈 노트는 공개된다.** 내부 IP·호스트명·사내 제품명·계정을 넣지 않는다. 커밋 훅은 커밋만 막고
   릴리즈 본문은 못 막는다. 여기서 걸러야 한다.
3. **버전이 여러 곳에 있으면 전부 올린다.** 하나만 올리고 릴리즈하면 실행 파일이 옛 버전을 보고한다.
4. **이전 릴리즈 형식을 그대로 따른다.** 내가 형식을 새로 정하지 않는다.
5. **릴리즈 전에 검증할 게 있으면 먼저 한다.** 태그는 검증 뒤에 찍는다.

## 실행 그래프

| # | 단계 | 의존 | 게이트(통과조건) |
|---|------|------|------------------|
| 0 | **동시 세션 확인** | - | 다른 세션 없음 |
| 1 | **릴리즈 범위 확정** | 0 | 어느 repo 들, 어느 버전, 무엇부터 무엇까지 |
| 2 | 이전 릴리즈 형식 조사 | 1 | 노트 구조·분류·인용 대상 확보 |
| 3 | **버전이 적힌 곳 모두 갱신** | 1 | 코드·설정에 적힌 버전이 전부 새 값 |
| 4 | 변경 목록 수집 | 2 | 이전 태그 이후 커밋을 분류 |
| 5 | **노트 초안 승인** (블로킹) | 3,4 | 사용자가 본문을 확인 |
| 6 | 커밋 · 태그 · push | 5 | 태그가 원격에 올라감 |
| 7 | 릴리즈 생성 · 바이너리 첨부 | 6 | 릴리즈가 만들어지고 에셋 목록이 이전과 같음 |
| 8 | CD 이미지 대기 | 6 | 레지스트리에 새 태그가 보임 |
| 9 | **연동 repo 보고** | 8 | 따라가야 할 곳과 고칠 자리를 보고. 지목받았을 때만 반영 |
| 10 | 배포 | 9 | `deploy-verify` 로 넘긴다 |

## 0. 동시 세션 확인

태그와 릴리즈는 되돌리기 어렵다. 남이 같은 repo 에서 작업 중이면 내가 안 넣은 커밋이 태그에 들어간다.

```sh
~/.claude/skills/shared/scripts/session-guard.sh <repo> 10
git status --porcelain | head
```

| 상황 | 행동 |
|------|------|
| 다른 세션 없음 | 진행 |
| 있음, 또는 **확인 불가(exit 2)** | `git add -A` 를 쓰지 않는다. 경로를 지정해 add 하고, 태그에 무엇이 들어가는지 먼저 보여준다 |
| 워킹트리에 남의 미커밋 변경 | 그 분량은 빼고 간다. 태그는 커밋된 것만 가리킨다 |

절차 → `../shared/references/concurrent-sessions.md`

## 1. 릴리즈 범위 확정

여러 repo 를 한 번에 올리는 일이 잦다.

> "collector, workflow, migrator **모두 v0.6.0 릴리즈** 해줘"

확인할 것:
- 어느 repo 들, 각각 어느 버전
- **기준 구간** - `v0.5.0 부터 지금까지` 인지 `직전 태그 이후` 인지. 여기서 갈리면 노트 전체가 어긋난다
- 이미 있는 태그를 다시 찍는 것인지 (`태그 다시 찍어서 force push`) - 그러면 별도 승인이다
- 릴리즈 전에 검증할 게 있는지

## 2. 이전 릴리즈 형식 확인

**형식을 지어내지 않는다.** 그 repo 의 직전 릴리즈를 그대로 본다.

```sh
gh release view --repo <owner>/<repo> "$(gh release list --repo <owner>/<repo> -L1 --json tagName -q '.[0].tagName')"
git tag --sort=-v:refname | head -5
git log --oneline -20 --format='%s'        # 커밋 제목 스타일(언어·접두사)
```

세션에서 실제로 쓰인 구조 → `references/notes.md`. 섹션 이름이 바뀐 전례가 있으니
**직전 릴리즈를 정본으로 삼는다.**

> "`Integrated or tested with` 이거는 `Tested With` 이라고 쓰고"
> "`commonmodel` 은 이제 없어"

## 3. 버전이 적힌 곳 모두 갱신

버전은 코드 안에도 적혀 있다. 태그만 찍으면 실행 파일은 옛 버전을 그대로 말한다.

```sh
grep -rIn "v\?$OLD" --include='*.go' --include='*.yaml' --include='*.yml' \
  --include='*.json' --include='Makefile' --include='*.txt' . | grep -v vendor/ | head -20
```

| 형태 | 예 |
|------|-----|
| 실행 파일 버전 상수 | `agent/cmd/<name>/main.go` 의 버전 변수 |
| 버전 파일 | `edge-telegraf_version.txt` 같은 빌드 입력 |
| compose·차트의 자기 이미지 태그 | `docker-compose.yaml` |

**하위 컴포넌트 버전을 먼저 올린다.** agent 가 있는 repo 는 agent 버전 커밋이 릴리즈보다 앞이다.
실제 커밋: `agent: Bump the version to v0.6.1`.

> "collector 같은 경우는 **agent 버전 먼저** v0.6.0 으로 하고 릴리즈하고 바이너리들 업로드"

## 4. 변경 목록 수집

직전 태그 이후 커밋을 모아 분류한다.

```sh
git log --oneline "$PREV..HEAD" --no-merges --format='%h %s'
```

이전 릴리즈의 분류를 그대로 쓴다 (세션에서 쓰인 것: New Features / Enhancements / Bug Fixes).
**분류를 못 하겠는 커밋은 묻는다.** 임의로 Bug Fixes 에 넣지 않는다.

머지 커밋과 남의 PR 커밋을 섞지 않는다. 그 repo 의 기존 노트가 어떻게 다뤘는지 본다.

## 5. 노트 초안 승인 (블로킹)

**본문 전체를 보여주고 승인받는다.** 승인 전에 태그를 찍지 않는다.

같이 짚을 것:
- `Tested With` 에 적는 연동 모듈 버전을 **어디 기준으로 썼는지** (실제 배포 스택 기준인 경우가 많다)
- 공개 노출 검사 결과 - 내부 IP·호스트명·사내 제품명·계정이 없다는 것
- AI 생성 문구, `🤖`, `## Summary` 같은 템플릿을 쓰지 않았다는 것

## 6. 커밋 · 태그 · push

```sh
git add <경로들>          # git add -A 를 쓰지 않는다
git commit -m "<그 repo 스타일>"
git tag <vX.Y.Z>
git push origin <branch> && git push origin <vX.Y.Z>
```

이미 있는 태그를 옮기는 것이면 **다시 묻는다.** 남이 그 태그를 이미 받아 갔을 수 있다.

## 7. 릴리즈 생성 · 바이너리 첨부

**승인받은 노트로 릴리즈를 만든다.** 태그만 밀면 릴리즈는 생기지 않는다.

```sh
gh release create <vX.Y.Z> --repo <owner>/<repo> --title "<vX.Y.Z>" --notes-file <노트파일>
```

릴리즈에 바이너리를 올리는 repo 가 있다. **이전 릴리즈의 에셋 목록과 같은 조합인지 대조한다.**

```sh
gh release view <이전태그> --repo <owner>/<repo> --json assets -q '.assets[].name'
```

빠진 아키텍처가 있으면 그대로 두지 말고 알린다. `arm64` 는 빌드는 되는데 배포 경로가 없던 전례가 있다.

## 8. CD 이미지 대기

태그를 밀면 CD 가 이미지를 만든다. **완성 전에 연동 repo 를 갱신하면 없는 이미지를 가리킨다.**

```sh
gh run list --repo <owner>/<repo> -L3
for i in $(seq 1 40); do            # 40 × 30s = 20분 상한
  gh run list --repo <owner>/<repo> -L1 --json status,conclusion -q '.[0]|.status+" "+(.conclusion//"-")'
  sleep 30
done
```

**상한 없는 폴링을 하지 않는다.** 상한에 걸리면 멈추고 알린다.

## 9. 연동 repo 보고

여기가 가장 자주 빠진다. 릴리즈는 됐는데 그 버전을 가리키는 곳을 안 고쳐서, 배포는 성공하고
노드는 옛 이미지로 계속 뜨는 상태가 된다.

```sh
~/.claude/skills/shared/scripts/downstream-scan.sh <repo> -q
```

**보고만 한다. 고치지 않는다.** 연동 repo 는 지시받은 범위 밖이다.
어디를 어떻게 고쳐야 하는지까지 적어서 올리고, 사용자가 그 repo 를 지목하면 그때 반영한다.
절차 → `../shared/references/downstream.md`

> "릴리즈 한거 CD 다 돌아서 Docker Image 완성되면 **stackctl 의 docker-compose.yaml 에 v0.5.2 박은 다음에**"

이 인용처럼 사용자가 그 repo 를 함께 지목했으면 반영까지 간다. 그때도 **CD 가 이미지를 다 만든 뒤**다.
없는 이미지를 가리키는 커밋을 먼저 밀지 않는다.

## 10. 배포

`deploy-verify` 로 넘긴다. 반영 확인까지가 그쪽 몫이다.
실제로 새 버전이 실행되는지는 `verify-impl` 이 본다.

## 하지 말 것

- 승인 없이 태그·릴리즈 생성
- 이전 릴리즈를 안 보고 노트 형식을 새로 만들기
- 릴리즈 노트에 내부 IP·호스트명·사내 제품명·계정 넣기
- AI 생성 문구·템플릿 (`## Summary`, `🤖 Generated with`)
- 하위 컴포넌트(agent 등) 버전을 안 올리고 릴리즈
- 코드에 박힌 버전을 놔두고 태그만 찍기
- CD 이미지 완성 전에 연동 repo 버전 갱신
- 상한 없는 CD 폴링
- 연동 repo 반영을 승인 없이 하기
- 검증이 남았는데 태그부터 찍기
- 릴리즈했다고만 하고 어디에 무엇이 올라갔는지 안 남기기
