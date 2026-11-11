# hwp / hwpx 작업

why-hwp(<https://github.com/jollaman999/why-hwp>, Go 실행 파일 하나)로 읽고 변환한다.
Python·Java 가 없어도 된다. 설치 때 릴리즈를 받아 `~/.claude/skills/doc-write/bin/` 에 둔다.

## 1. 도구 찾기

```sh
WH=$(bash ~/.claude/skills/doc-write/scripts/fetch-why-hwp.sh --which) || echo "why-hwp 없음"
```

| 찾는 순서 | 무엇 |
|-----------|------|
| 1 | `WHY_HWP_BIN` (폐쇄망에서 직접 옮긴 실행 파일) |
| 2 | PATH 의 `why-hwp` |
| 3 | `~/.claude/skills/doc-write/bin/why-hwp[.exe]` (설치 때 받은 것) |

없으면 `bash ~/.claude/skills/doc-write/scripts/fetch-why-hwp.sh` 로 받는다. 못 받으면 hwp 작업을 못 한다고 알리고 멈춘다.

## 2. 지금 있는 명령

| 명령 | 하는 일 | 플랫폼 |
|------|---------|--------|
| `text [-format plain\|json] <파일>` | `.hwpx`·`.docx` 글을 `<위치><TAB><글>` 로. `s0/p12` 는 0번 구역 12번 문단, `s0/p3/t0/r1/c2` 는 3번 문단 첫 표의 1행 2열. 메모·머리말·꼬리말·각주는 빠진다 | 전부 |
| `info [-format plain\|json] <파일>` | 구역·문단 수, 표와 크기, `(A)`·`(A/B)` 담당 표기와 위치, 메모, 변경 추적, 스타일, 그림 | 전부 |
| `convert [-to hwp\|hwpx\|pdf\|txt] [-o 출력] [-force] <입력>` | 설치된 한컴오피스로 변환. 출력이 있으면 `-force` 없이는 안 덮어쓴다 | 한글이 깔린 Windows |
| `svg2png [-width-mm N \| -width-px N] [-dpi 600] [-trim] [-o out.png] <in.svg>` | SVG 를 들어갈 너비에 맞춘 PNG 로. headless Chrome·Edge·Chromium·Firefox | 브라우저 있는 곳 |
| `version` | 버전 | 전부 |

**`.hwp` 는 `text`·`info` 가 아직 못 읽는다.** `convert -to hwpx` 로 사본을 만들어 읽는다.
한글이 없는 곳이면 hwpx 나 pdf 로 달라고 한다.

## 3. 작업 순서

| # | 할 일 | 명령·방법 |
|---|-------|-----------|
| 1 | 원본을 복사한다. 원본은 고치지 않는다 | 사본 이름은 폴더 파일명 규칙의 다음 버전 |
| 2 | `.hwp` 면 hwpx 사본을 만든다 | `"$WH" convert -to hwpx -o 사본.hwpx 원본.hwp` |
| 3 | 구조와 글을 뽑는다 | `"$WH" info 사본.hwpx`, `"$WH" text 사본.hwpx > 원본.txt` |
| 4 | 모양을 본다 | `"$WH" convert -to pdf -o 사본.pdf 사본.hwpx` 후 Read 로 쪽을 본다 |
| 5 | 분석·질문 (`questions.md`) | 담당 표기, 메모, 변경 추적 개수를 적어 둔다 |
| 6 | hwpx 를 고친다 | 5절 |
| 7 | 그림을 넣는다 | `"$WH" svg2png -width-mm <영역 mm> ...` 후 5절의 그림 규칙 |
| 8 | 검증한다 | 6절 |
| 9 | 제출 형식이 `.hwp` 면 변환한다 | `"$WH" convert -to hwp -o 결과.hwp 결과.hwpx` |

## 4. HWPX 구조

| 무엇 | 사실 |
|------|------|
| 묶음 | zip. `mimetype` 이 **첫 항목이고 무압축(Stored)** |
| 본문 | `Contents/section0.xml` (구역마다 `sectionN.xml`) |
| 서식·저자·변경 추적 목록 | `Contents/header.xml` |
| 목록(manifest) | `Contents/content.hpf` |
| 그림 파일 | `BinData/` |

## 5. hwpx 를 고치는 법 (why-hwp apply 가 들어오기 전)

**`why-hwp apply` 가 들어오면 이 절을 그 명령으로 바꾼다.** 그 전에는 hwpx 의 XML 을 직접 고친다.
아래 규칙은 실제 문서를 고치며 확인한 것이다.

| 규칙 | 왜 |
|------|-----|
| 고친 문단의 `<hp:linesegarray>` 는 지운다 | 남기면 한글이 앞쪽 일부 쪽까지만 연다 (19쪽에서 멈춘 일) |
| 서식은 문서에 이미 있는 `paraPrIDRef`·`charPrIDRef` 를 쓴다. 같은 칸의 예시 문단에서 복사한다 | 새 서식 ID 를 만들면 header 와 어긋난다. 예시 스타일을 따르는 것이기도 하다 |
| 넣은 글은 변경 추적으로 감싼다: `<hp:insertBegin Id=".." TcId=".."/>` … `<hp:insertEnd Id=".." TcId=".." paraend="0\|1"/>`. 지운 글은 `deleteBegin`/`deleteEnd` | 한글 검토 화면에서 무엇을 바꿨는지 보인다 |
| header 의 `<hh:trackChanges itemCnt="N">` 아래에 `<hh:trackChange type="Insert\|Delete" date=".." authorID=".." hide="0" id=".."/>` 를 더하고 `itemCnt` 를 맞춘다. 저자는 `trackChangeAuthors` 에 | 목록과 본문 표시가 어긋나면 변경 추적이 깨진다 |
| 메모(`<hp:fieldBegin type="MEMO">` …)는 건드리지 않는다 | 남의 메모다 |
| 그림은 `hp:pic` 으로 넣는다. `treatAsChar=1`, 크기 `imgDim` 은 px × 75 (HWPUNIT). `binaryItemIDRef` 는 `content.hpf` 의 manifest 항목과 같아야 하고, 파일은 `BinData/` 에 | 어긋나면 그림이 안 나온다 |
| 다시 묶을 때 `mimetype` 을 첫 항목, 무압축으로 | 한글이 hwpx 로 알아보는 조건이다 |

**다시 묶는 법.** `zip` 명령이 있으면 이렇게 한다 (풀어 둔 폴더 안에서).

```sh
zip -X -0 ../결과.hwpx mimetype
zip -X -r ../결과.hwpx . -x mimetype
unzip -v ../결과.hwpx | head -5     # 첫 항목이 mimetype 이고 Method 가 Stored 인지 본다
```

이 명령 순서는 이 문서를 쓸 때 돌려 보지 않았다. **`unzip -v` 확인과 6절 검증을 꼭 거친다.**

**Windows Git Bash 에는 `zip` 이 없다** (2026-11-11 이 PC 에서 `command -v zip` 빈 결과).
PowerShell 의 .NET `ZipFile` 에 `NoCompression` 을 줘도 `mimetype` 이 Deflate 로 들어가 조건을 못 맞춘다
(2026-11-11 실측, `unzip -v` 에 `Defl:N`). `zip` 이 없으면 묶지 못한다고 알리고 멈춘다.

## 6. 검증

| 검사 | 어떻게 |
|------|--------|
| 열리나 | `"$WH" convert -to pdf` 가 끝까지 되고, PDF 마지막 쪽에 원본 마지막 쪽 글이 있는지. 앞쪽 일부만 나오면 5절 `linesegarray` 를 본다 |
| 남의 글이 그대로인가 | 원본과 결과에서 `text` 를 뽑아 diff. 우리 칸 밖의 줄이 바뀌었으면 안 된다 |
| 메모·변경 추적 | `info` 의 메모 수가 원본과 같고, 변경 추적이 이번에 고친 만큼 늘었는지 |
| 그림 | PDF 쪽에서 그림이 영역 안에 들어갔는지 눈으로 |
| 모양 | PDF 를 원본 PDF 와 나란히 보고 표가 깨지거나 쪽이 밀리지 않았는지 |

## 7. 한글 COM 과 저장의 함정

| 함정 | 어떻게 |
|------|--------|
| 한글 COM 이 `%TEMP%` 밖 경로에 저장할 때 파일 접근 허용 대화상자를 띄우고 멈춘다 | `convert` 가 임시 폴더 사본으로 작업해서 피한다. 한글 COM 을 직접 부르지 않는다 |
| 끝나지 않은 `Hwp.exe` 가 파일을 잠근다 | 잠겼으면 알리고 다른 이름으로 저장한다. 이미 떠 있는 한글은 사용자 것일 수 있어 **끝내지 않는다**. `convert` 는 자기가 띄운 한글만 닫는다 |
| OneDrive 같은 동기화 폴더에 바로 저장하면 멈출 수 있다 | 임시 폴더에 저장한 뒤 복사하고, 두 파일의 md5 가 같은지 본다 (`md5sum 임시본 복사본`) |
| `.hwp` 를 Go 로 직접 쓰는 기능은 없다 | 저장은 hwpx 로 하고, `.hwp` 가 필요하면 `convert -to hwp` |

## 8. docx 에서 글을 뽑을 때

`why-hwp text` 는 아래 두 함정을 처리한다. 다른 방법으로 뽑으면 직접 걸러야 한다.

| 함정 | 증상 |
|------|------|
| `wp:posOffset` 의 숫자 | 그림 위치 숫자가 본문 글에 섞인다 |
| `mc:AlternateContent` | 같은 글이 두 번 나온다 |
