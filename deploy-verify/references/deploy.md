# 배포 레시피

세션에서 실제로 쓰인 패턴이다. 새로 짜지 말고 여기서 고른다.

## 공통 규칙

- **`timeout` 필수.** 전송 300, 재기동 400, 조회 60.
- **`ssh -n` 필수.** 없으면 stdin 을 먹어 호출한 스크립트의 남은 줄과 루프를 삼킨다.
- `-o StrictHostKeyChecking=no`, 비밀번호는 변수로만.

## 도커 이미지 배포

```sh
# 로컬에서 저장
docker save <img>:<tag> | gzip > /tmp/img.tar.gz
LOCAL=$(md5sum /tmp/img.tar.gz | cut -c1-32)

# 전송
timeout 300 sshpass -p "$PW" scp -o StrictHostKeyChecking=no /tmp/img.tar.gz root@"$H":/data/docker/

# 전송 무결성 - 로드 전에 확인한다
REMOTE=$(timeout 60 sshpass -p "$PW" ssh -n -o StrictHostKeyChecking=no root@"$H" "md5sum /data/docker/img.tar.gz | cut -c1-32")
[ "$LOCAL" = "$REMOTE" ] || { echo "전송 깨짐"; exit 1; }

# 로드 + 재기동
timeout 400 sshpass -p "$PW" ssh -n -o StrictHostKeyChecking=no root@"$H" \
  "gunzip -c /data/docker/img.tar.gz | docker load && bash /data/scripts/run_<svc>.sh"
```

## 다중 호스트 - 한 대씩 (운영 권장)

```sh
for h in 10.0.0.11 10.0.0.12; do
  echo "===== $h ====="
  timeout 300 sshpass -p "$PW" scp -o StrictHostKeyChecking=no /tmp/img.tar.gz root@"$h":/data/docker/
  timeout 400 sshpass -p "$PW" ssh -n -o StrictHostKeyChecking=no root@"$h" "…로드+재기동…"
  scripts/deploy-wait.sh "$h" <svc> 120 || { echo "$h 실패 - 중단"; break; }
done
```

**한 대가 실패하면 멈춘다.** 나머지에 같은 실패를 퍼뜨리지 않는다.

## 반영 확인 (8단계)

```sh
# 파일 해시
echo "로컬: $(md5sum ./ansible.tar.gz | cut -c1-32)"
for h in 10.0.0.11 10.0.0.12; do
  echo -n "$h: "; timeout 60 ssh -n root@"$h" "md5sum /data/docker/ansible.tar.gz | cut -c1-32"
done

# 이미지 태그 + 기동 시각
timeout 60 ssh -n root@"$H" "docker inspect <svc> --format '{{.Config.Image}} {{.State.StartedAt}}'"

# 이미지 목록에서 방금 것 확인
timeout 60 ssh -n root@"$H" "docker images --format '{{.Repository}}:{{.Tag}} {{.CreatedSince}}' | head -5"
```

`StartedAt` 이 방금이 아니면 재기동이 안 된 것이다.

## 설정 파일만 배포

```sh
# 백업 먼저
timeout 60 ssh -n root@"$H" "cp /app-config/application.yaml /app-config/application.yaml.bak.$(date +%s)"
timeout 120 scp application.yaml root@"$H":/app-config/
timeout 400 ssh -n root@"$H" "bash /data/scripts/run_<svc>.sh"
```

**백업 없이 설정을 덮어쓰지 않는다.** 원복 경로가 있어야 재기동 승인을 받을 수 있다.

## 롤백

```sh
# 이전 이미지로
timeout 400 ssh -n root@"$H" "docker tag <img>:<prev> <img>:latest && bash /data/scripts/run_<svc>.sh"
# 설정 원복
timeout 400 ssh -n root@"$H" "cp /app-config/application.yaml.bak.<ts> /app-config/application.yaml && bash /data/scripts/run_<svc>.sh"
```

배포 전에 **이 명령을 미리 준비**해 둔다. 문제가 생긴 뒤에 찾으면 늦다.

## 폴링 함정

원격 작업 종료를 기다릴 때 두 가지를 지킨다.

1. **`pgrep -f "X"` 를 X 가 든 명령 안에서 쓰지 않는다.** 자기 자신을 매칭해 영원히 안 끝난다.
   `[m]cc` 처럼 대괄호로 깨거나, 종료 표식 파일(`test -f /tmp/x.done`)을 쓴다.
2. **`until` 에 횟수 상한을 건다.** `scripts/deploy-wait.sh` 는 이미 상한이 들어 있다.

폴링 전에 **기다릴 대상이 실제로 돌고 있는지** 먼저 본다. 이미 끝났으면 폴링할 이유가 없다.

## 금지

- 전송 무결성 확인 없이 로드
- 백업 없이 설정 덮어쓰기
- 운영 전체 동시 재기동 (묻고 한다)
- 실패한 호스트를 남기고 다음으로 진행
- `timeout` / `ssh -n` 없는 원격 명령
- 상한 없는 `until` 폴링
- `pgrep -f` 자기 매칭
