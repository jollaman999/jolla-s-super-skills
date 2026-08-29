# L 노드 - 로컬 구동 폴백

실제 노드 접속이 거부되거나 도달 불가일 때, **코드만 읽고 끝내지 않고 로컬에 띄워서** 실증한다.
정적 대조는 이것마저 불가능할 때의 마지막 수단이다.

## 구동 방법 탐지 (순서대로)

| 순위 | 신호 | 명령 |
|------|------|------|
| 1 | `docker-compose*.yml` / `compose.yml` | `docker compose up -d` |
| 2 | `Makefile`에 `up`/`run`/`dev` 타깃 | `make up` |
| 3 | Go - `main.go`, `cmd/` | `go run ./cmd/...` 또는 `go build && ./bin` |
| 4 | Node - `package.json` scripts | `npm run dev` / `npm start` |
| 5 | Java - `gradlew`/`mvnw` | `./gradlew bootRun` |

`README`의 "how to run"을 먼저 본다. 프로젝트가 정한 방법이 있으면 그걸 따른다.

## 띄우기 전에 반드시 묻는다

포트를 점유하고 리소스를 쓰기 때문이다. 함께 알릴 것:

- 사용할 포트와 이미 점유 중인지 (`ss -ltnp | grep :8080`)
- 필요한 외부 의존 - DB·큐·외부 API. **이게 없으면 어떤 항목은 검증 불가**임을 미리 말한다.
- 예상 소요와 디스크/이미지 다운로드 여부

## 헬스체크 통과해야 F로 간다

```sh
scripts/health-wait.sh http://localhost:8080/health 60
# 또는 compose
docker compose ps --format '{{.Service}} {{.Health}}'
```
안 뜨면 **로그를 먼저 본다** (`docker compose logs --tail 50`). 안 뜬 채로 검증을 시작하지 않는다.

## 로컬 구동의 한계 - 보고서에 명시한다

| 검증 못 하는 것 | 이유 |
|-----------------|------|
| 실 데이터 기반 동작 | 로컬 DB는 비어 있음 |
| 노드 하드웨어 의존 (GPU/NIC) | 로컬에 없음 |
| 사이트 간 설정 차이 | 로컬은 한 벌뿐 |
| 실제 네트워크 경로·방화벽 | 재현 안 됨 |
| 운영 데이터 규모에서의 성능 | 재현 안 됨 |

이 항목들은 `unknown` + 이유로 남기고, "로컬에서 확인됨"을 "실제로 동작함"으로 보고하지 않는다.

## 정리

검증이 끝나면 **띄운 것을 내린다** (`docker compose down`). 남겨둘지 먼저 묻는다.
생성한 임시 파일·볼륨도 정리 대상이다.
