# doc-write

**자료를 전부 읽고, 정할 것을 한 번에 물은 뒤 문서를 씁니다.**

> "보고서 써줘", "이거 md 로 뽑아줘", "발표 자료 만들어줘", "그림도 넣어줘", "MR 초안 써줘"

다른 skill 은 코드와 노드를 다룹니다. 문서는 그 밖이었고, 문서에서 나온 교정은 늘 같은 종류였습니다.

| 교정 | 실제로 들은 말 |
|------|----------------|
| 독자를 안 정하고 씀 | "코드 적으로 말고 이거 발표 자료로 쓸거야 남들이 볼때 이해할수 있게" |
| 양식·예시를 무시함 | "예시가 있는데 스타일을 왜 다 무시하고" |
| 남의 몫을 우리 몫처럼 씀 | "왜 자꾸 니는 우리쪽으로 몰을려그래" |
| 못 읽은 자료를 추정으로 채움 | "모둘별로 뭐할지 계획한 파일들 준것들에 대한 내용은 어따 팔아먹었냐" |
| 산출물을 잃음 | "이거 내용을 다 지워 버렸네" |

## 전제

**담당·기관·과제 이름은 이 skill 에 없습니다.** 문서마다 다르기 때문입니다. 자료에서 뽑아 근거와 함께 묻습니다.

**쓰기 전에 한 번 묻습니다.** 자료를 분석한 뒤 담당 부분, 협업 기관 몫, 독자, 그림 종류,
그림 시안을 먼저 볼지, 파일명을 한 표로 묻습니다. 질문마다 추천 답이 붙어 "그대로" 한 마디로 넘어갈 수 있습니다.

**덮어쓰지 않습니다.** 버전을 올려 새 파일로 두고, git 밖이면 지우면 못 되살린다고 알립니다.

## 흐름

```
자료 전부 열기            (못 연 것이 있으면 알리고 멈춤)
  -> 분석                 (양식 칸, 담당 표기, 협업 기관, 최신 분담 근거, 파일명 규칙, 예시 스타일)
  -> 질문 한 번           (블로킹. 분석 근거와 추천 답을 붙여서)
  -> 쓰기                 (최종본으로, 우리 몫만, 양식·예시 그대로)
  -> 그림                 (SVG 원본. 시안 확인을 골랐으면 한 장 먼저)
  -> 결과물               (md, txt, hwp/hwpx, pptx, docx)
  -> 검증                 (원본 대비, 수치, 내부 이름, 그림 렌더, 경로)
  -> 보고                 (보실 문서 경로 하나)
```

## 그림

원본은 항상 SVG 입니다. 출력에 따라 넣는 방식만 다릅니다.

| 출력 | 넣는 것 |
|------|---------|
| md | SVG 그대로 |
| hwp/hwpx | 들어갈 영역 너비에 맞춘 600 dpi PNG (`why-hwp svg2png -width-mm`) |
| pptx | 템플릿의 네이티브 도형 |

발표·외부용은 직접 설계한 그림이고, 개발자 repo 문서는 그 repo 의 그림 규약(Mermaid 등)을 따릅니다.

## why-hwp

hwp/hwpx 를 읽고 변환하고 SVG 를 PNG 로 만드는 도구입니다 ([jollaman999/why-hwp](https://github.com/jollaman999/why-hwp)).
Go 실행 파일 하나라 Python 이나 Java 가 없어도 됩니다.

**실행 파일은 이 repo 에 넣지 않습니다.** `install.sh` 가 설치 끝에 GitHub 릴리즈에서 OS·아키텍처에 맞는 것을 받아
SHA256SUMS 로 확인한 뒤 `doc-write/bin/` 에 둡니다. 못 받아도 설치는 끝나고, hwp 작업만 못 합니다.

```sh
bash ~/.claude/skills/doc-write/scripts/fetch-why-hwp.sh            # 없으면 받는다
bash ~/.claude/skills/doc-write/scripts/fetch-why-hwp.sh --check    # 무엇을 쓰는지만 본다
bash ~/.claude/skills/doc-write/scripts/fetch-why-hwp.sh --force    # 새 릴리즈로 바꾼다
WHY_HWP_VERSION=v0.3.0 bash ~/.claude/skills/doc-write/scripts/fetch-why-hwp.sh   # 버전을 정해서
```

| 상황 | 어떻게 |
|------|--------|
| 폐쇄망 | 실행 파일을 직접 옮기고 `WHY_HWP_BIN=<경로>` 를 주거나 PATH 에 둡니다. 그러면 받지 않습니다 |
| 사내 미러 | `WHY_HWP_BASE_URL` 과 `WHY_HWP_VERSION` 을 같이 줍니다 |
| 최소 버전 | 스크립트의 `MIN_VERSION` 보다 낮으면 쓰지 않고 알립니다 |

`convert`(hwp ↔ hwpx, pdf, txt)와 `svg2png` 는 why-hwp 에 든 엔진으로 Windows·Linux·macOS 어디서나 됩니다. PDF 는 한글 인쇄의 근사라 모양 확인용이고, 한글과 똑같은 PDF 는 한컴오피스가 깔린 Windows 에서 `convert -engine hancom` 으로 만듭니다.

## 참고 문서

| 파일 | 무엇 |
|------|------|
| [`references/questions.md`](references/questions.md) | 분석 방법과 처음 질문 |
| [`references/writing.md`](references/writing.md) | 쓰기 규칙과 근거 발화 |
| [`references/figures.md`](references/figures.md) | 그림 원칙, 스타일, 넣는 법, 검사 |
| [`references/hwp.md`](references/hwp.md) | hwp/hwpx 작업 순서와 함정 |
| [`references/formats-submit.md`](references/formats-submit.md) | 정부과제 보고서·사업계획서·요구사항·제안서·SW 등록 명세서 |
| [`references/formats-present.md`](references/formats-present.md) | 발표 pptx, 발표·리뷰용 md |
| [`references/formats-repo.md`](references/formats-repo.md) | 외부 README, 설계 문서, 협업 기관 공유 문서, 개발자 문서, 시험 기록 |
| [`references/formats-draft.md`](references/formats-draft.md) | 메일, MR·PR, Jira, Slack |

## 다른 skill 과

| 이럴 때 | 어디로 |
|---------|--------|
| 문서가 산출물 | 여기 |
| 문서를 만드는 도구·스크립트·코드를 만든다 | [`design-first`](../design-first/) |
| 릴리즈 노트 | [`release-cut`](../release-cut/) |
| 문서 내용이 지금 동작과 맞는지 확인만 | [`verify-impl`](../verify-impl/) |
