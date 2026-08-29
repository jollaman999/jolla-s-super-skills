# 릴리즈 노트 - 지금까지 실제로 써 온 모양

**기준은 그 repo 의 직전 릴리즈다.** 이 문서는 형식을 지어내지 않기 위한 참고이지 템플릿이 아니다.
섹션 이름이 바뀐 전례가 있다 (`Integrated or tested with` → `Tested With`).

## 생김새 (여러 모듈을 한 스택으로 묶어 쓰는 경우)

```markdown
## Tested With
* provisioner [v0.5.5](https://github.com/acme/provisioner/releases/tag/v0.5.5)
* orchestrator [v0.12.25](...)
* csp-broker [v0.12.35](...)

## API docs
* Swagger UI URL: https://acme.github.io/api/?url=.../swagger.yaml

## How to run
* https://github.com/<owner>/<repo>?tab=readme-ov-file#how-to-run

## What's Changed

### New Features
* [scope: Title](커밋 링크)

### Enhancements
* [scope: Title](커밋 링크)

### Bug Fixes
* [scope: Title](커밋 링크)

**Full Changelog**: https://github.com/<owner>/<repo>/compare/vA...vB
```

## 사람마다 다르게 채우는 자리

| 항목 | 판단 |
|------|------|
| `Tested With` 의 버전 | **실제 배포 스택 기준**으로 쓴 전례가 있다. 무엇을 기준으로 할지 묻는다. |
| 목록에서 빠지는 모듈 | 더 안 쓰는 모듈이 생긴다. 이전 노트를 그대로 베끼지 않는다. |
| 항목 문구 | 커밋 제목을 그대로 쓴다. 그 repo 는 영어 + `scope: Verb ...` 다. |
| 분류가 애매한 커밋 | 묻는다. 임의로 Bug Fixes 에 넣지 않는다. |
| 남의 PR·머지 커밋 | 이전 노트가 어떻게 다뤘는지 먼저 본다. |

## 올리기 전에 - 내부 정보가 섞이지 않았는지

릴리즈 본문은 공개된다. 커밋 훅은 커밋만 막는다.

```sh
grep -nE '192\.168\.|10\.[0-9]+\.|172\.(1[6-9]|2[0-9]|3[01])\.|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' <노트파일>
grep -niE '<사내 제품·조직명>|password|token|@[a-z]+\.com' <노트파일>
```

걸리면 값을 빼고 서술로 바꾼다. `"테스트베드에서 확인"` 이면 충분하고 주소는 필요 없다.

## 쓰지 않는 것

- `## Summary`, `## Test plan`, 체크박스
- `🤖 Generated with Claude Code`
- `Co-Authored-By`
- em dash
