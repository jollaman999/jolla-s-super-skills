# F 노드 - 원격 실증 레시피

세션에서 실제로 쓰인 패턴을 표준화한 것이다. 새로 짜지 말고 여기서 골라 쓴다.

## 기본형

```sh
timeout 240 sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -p "$PORT" root@"$HOST" '원격명령'
# 키 방식
timeout 240 ssh -i /path/key -o StrictHostKeyChecking=no ubuntu@"$HOST" '원격명령'
```

- **`timeout`은 필수.** 원격 명령이 멈추면 세션 전체가 묶인다. 조회 60, 재기동/빌드 240~400.
- `-o StrictHostKeyChecking=no` - 신규 호스트에서 프롬프트로 멈추지 않게.
- **`ssh -n` 필수** - 없으면 ssh 가 stdin 을 먹어 호출한 스크립트의 남은 줄과 `for`/`until` 루프를 통째로 삼킨다.
- 일회성 호스트는 `-o UserKnownHostsFile=/dev/null`도 추가.
- 비밀번호는 **변수로만**. 명령 원문을 evidence에 넣을 때 값이 전개되면 안 된다.

## 점프 호스트 2단

```sh
timeout 240 sshpass -p "$PW" ssh -o StrictHostKeyChecking=no root@"$JUMP" \
  "ssh -i /root/inner_key -o StrictHostKeyChecking=no inner@$INNER 'nvidia-smi --query-gpu=uuid --format=csv'"
```
바깥은 `"`, 안쪽은 `'`. 안쪽에서 `$`를 쓸 거면 `\$`로 이스케이프한다.

## 다중 호스트 (★2 병렬군의 각 Agent가 자기 호스트만 담당)

Agent별로 나누는 게 기본이지만, 한 Agent 안에서 훑을 때:

```sh
for h in "10.0.0.11 22" "203.0.113.20 2002" "10.0.0.12 22"; do
  set -- $h
  echo "===== $1 ====="
  timeout 60 sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -p "$2" root@"$1" '명령' 2>&1
done
```

## 상태 폴링 (배포·재기동 후)

```sh
timeout 400 ssh -o StrictHostKeyChecking=no -p "$PORT" root@"$HOST" \
  "bash /data/scripts/run_svc.sh 2>&1 | tail -4;
   for i in \$(seq 1 20); do
     s=\$(docker inspect svc --format '{{.State.Health.Status}}' 2>/dev/null)
     echo \"[\$i] \$s\"; [ \"\$s\" = healthy ] && break; sleep 5
   done"
```
`scripts/health-wait.sh`가 이걸 감싸 놓았다. 무한 대기 금지 - 반드시 횟수 상한.

## 서비스 로그

```sh
timeout 60 ssh ... "docker logs --tail 80 --since 10m svc 2>&1"
timeout 60 ssh ... "journalctl -u svc --no-pager -n 80 --since '10 min ago'"
```
`--since`로 자른다. 전체 로그를 끌어오면 컨텍스트만 태운다.

## DB로 결과 재확인 (API 응답만 믿지 않는다)

```sh
timeout 60 ssh ... "docker exec svc-db sh -c \"mysql -u\$U -p\$P dbname -N -e 'select id,status from t where id=1'\""
timeout 60 ssh ... "docker exec influxdb influx query 'from(bucket:\"b\") |> range(start:-5m) |> limit(n:5)'"
```
쓰기 검증은 **반드시** 이 단계까지 간다. 201만 보고 pass 하지 않는다.

## 배포 반영 대조 (고쳤는데 반영이 안 된 상황 차단)

```sh
echo "로컬: $(md5sum ./ansible.tar.gz | cut -c1-32)"
for h in 10.0.0.11 10.0.0.12; do
  echo -n "$h: "; timeout 60 ssh ... root@$h "md5sum /data/docker/ansible.tar.gz | cut -c1-32"
done
# 이미지 태그
timeout 60 ssh ... "docker inspect svc --format '{{.Config.Image}}'; docker images --format '{{.Repository}}:{{.Tag}} {{.CreatedSince}}' | head -5"
```

## 원격에 스크립트 보내 실행 (명령이 길 때)

```sh
S="$SCRATCH/check.sh"
cat > "$S" <<'SCRIPT'
#!/bin/sh
echo "=== 1 ==="; ...
SCRIPT
timeout 120 sshpass -p "$PW" scp -o StrictHostKeyChecking=no "$S" root@"$HOST":/tmp/check.sh
timeout 240 sshpass -p "$PW" ssh -o StrictHostKeyChecking=no root@"$HOST" 'sh /tmp/check.sh; rm -f /tmp/check.sh'
```
따옴표 중첩이 3단 이상 되면 무조건 이 방식으로 간다.

## 금지

- `timeout` 없는 원격 명령
- 승인 안 된 호스트 접속
- 승인 안 된 재기동·쓰기·삭제
- 비밀번호를 evidence/보고서에 평문으로
- `--since`/`tail` 없는 전체 로그 수집
