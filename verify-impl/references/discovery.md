# A·B·C 노드 상세 - 탐색과 선정

## 기능 인벤토리 뽑는 순서

1. **진입점부터.** 내부 유틸이 아니라 외부에서 찔러볼 수 있는 표면이 검증 대상이다.
   - HTTP: 라우터 등록부 (`router.`, `app.get`, `@RestController`, `urlpatterns`, `Route::`)
   - CLI: argparse/cobra/commander 서브커맨드 등록부
   - 비동기: 큐 소비자, cron/scheduler 등록, 이벤트 핸들러
   - gRPC/GraphQL: `.proto` service, resolver map
2. **각 진입점의 계약을 읽는다.** 요청/응답 타입, 검증 로직, 인가 미들웨어.
3. **부작용을 표시한다.** DB write / 외부 API 호출 / 파일 / 메시지 발행 - 파괴적 호출 판정의 근거가 된다.

출력 형태:

| 기능 | 진입점 | 입력 | 부작용 | 의존 |
|------|--------|------|--------|------|
| VM 생성 | `POST /api/v1/vm` handler.go:142 | VMSpec JSON | DB write, CSP API 호출 | postgres, aws-sdk |

## 심층 대상 선정

아래 신호가 있으면 심층 대상으로 올린다. 없으면 얕게 본다.

| 신호 | 왜 |
|------|-----|
| 인증·인가 분기가 있다 | 여기 구멍은 조용하고 치명적 |
| 상태를 바꾼다 (write/delete) | 잘못 돌면 되돌리기 어려움 |
| 외부 시스템 경계 | 목/스텁으로 통과하고 실제로는 깨지는 전형적 지점 |
| 최근 변경됨 (`git log`) | 회귀 확률 높음 |
| 테스트가 없다 | 아무도 안 봤다는 뜻 |
| 에러 경로가 분기 많음 | 정상 경로만 검증하면 놓침 |

선정 결과는 반드시 **선정 이유 한 줄**을 달아 제시한다. 이유 없는 우선순위는 사용자가 E에서 판단할 수 없다.

## 접속 대상 스캔 위치

우선순위 순:

1. `.claude/verify-targets.md` - 있으면 여기서 끝. 재질문 금지.
2. `README*`, `docs/`, `CONTRIBUTING*` - "how to run", "endpoint", "swagger" 근처
3. `.env.example`, `.env.sample`, `config/*.yaml|toml|json`
4. `docker-compose*.yml` - `ports:`, `environment:`
5. `k8s/`, `helm/`, `*.tf` - Service/Ingress host, output
6. `.github/workflows/`, `Makefile` - 실행 커맨드와 기본 포트
7. OpenAPI/Swagger 스펙 (`openapi.*`, `swagger.*`) - 있으면 체크리스트 항목의 금광

**주의:** `.env` (example이 아닌 실제 파일)에서 값을 읽어 출력하거나 기록하지 않는다. 변수명만 확인한다.

## 프론트엔드 존재 판정

다음 중 하나면 프론트 겸용으로 본다:
- `package.json`에 react/vue/svelte/next/nuxt/angular 의존
- `src/pages`, `src/app`, `src/components`, `public/index.html`
- 백엔드가 정적 파일을 서빙 (`static/`, `templates/`, `embed.FS`)
- 별도 디렉터리 (`web/`, `frontend/`, `ui/`, `console/`)

겸용이면 B′에서 프론트 URL·로그인 정보·연계 검증 여부를 함께 묻는다.
