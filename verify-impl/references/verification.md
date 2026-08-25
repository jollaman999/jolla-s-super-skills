# F·F′ 노드 - 검증 실행 규칙

## 공통

- **호스트 하나 = Agent 하나** (★2). 각 Agent가 자기 호스트의 전 항목을 돌린다.
- 각 Agent 반환 (자연어 서술 금지):

```json
{"host":"10.0.0.11","results":[{"id":"VF-01","verdict":"pass|fail|unknown","evidence":"출력 원문","cmd":"실행 명령"}]}
```

- `evidence`는 **가공하지 않은 출력**. 요약하지 않는다. 시크릿만 마스킹.
- 판단이 안 서면 `unknown`. **`unknown`을 `pass`로 올리지 않는다.**
- 코드가 그렇게 쓰여 있다는 것은 그렇게 동작한다는 증거가 아니다.

## 수단별 규칙

### ssh (최우선)
`scripts/ssh-run.sh`를 쓴다 - timeout·마스킹·점프호스트 내장, exit 0/1/2 = pass/fail/unknown.
```sh
VH_HOST=10.0.0.11 VH_PW="$PW" VH_TO=60 scripts/ssh-run.sh VF-01 'docker inspect svc --format "{{.State.Health.Status}}"'
```
직접 짤 때도 규칙 동일: `timeout` 필수, `StrictHostKeyChecking=no`, 비밀번호는 변수로.
레시피 → `ssh.md`

### log
`--since` / `--tail`로 자른다. 전체 로그 수집 금지.
에러가 없다는 것만으로 pass 하지 않는다 - **기대한 동작의 흔적이 있어야** pass다.

### db
쓰기 검증은 **반드시** 여기까지 온다. API가 201을 줬다는 것은 저장됐다는 증거가 아니다.

### deploy
"고쳤는데 반영이 안 된" 상황을 차단한다. `md5sum` 로컬 vs 원격, 이미지 태그·빌드 시각.
검증 대상이 **내가 고친 그 코드가 맞는지** 먼저 확인하고 나머지를 돌린다.

### front
`frontend.md` 절차.

### static (최후)
ssh도 로컬 구동도 불가할 때만. `file:line` + 코드 2~5줄 인용.
보고서에 **`(정적)` 표시 필수**. 실증된 것과 섞지 않는다.

## 적대적 교차검증

`pass` 항목만 대상. 항목별 Agent 동시 호출(★3). 지시문 원문:

> 다음 pass 판정을 **반증하라**. 4가지를 각각 확인한다:
> 1. **우연 통과** - 판정기준이 느슨해서 깨진 구현도 통과하는가? (예: "200이면 pass"인데 body가 빈 배열)
> 2. **잘못된 대상** - 검증하려던 그 코드 경로가 실제로 실행됐다는 증거가 있는가? 옛날 바이너리/이미지를 찌른 건 아닌가?
> 3. **가짜 응답** - 캐시·목·스텁·고정 응답일 가능성은? 재기동 전 상태를 본 건 아닌가?
> 4. **기준 오류** - 판정기준이 실제 요구사항과 어긋나 있지 않은가?
>
> 불확실하면 `refuted: true`를 기본값으로 한다.
> 반환: `{"id":"…","refuted":true|false,"reason":"…"}`

`refuted=true` → 최종 verdict `disputed`. 보고서에서 pass와 분리 표기.
