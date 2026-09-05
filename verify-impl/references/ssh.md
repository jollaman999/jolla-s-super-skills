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
- **Windows 는 키 인증(`VH_KEY`)이 기본이다.** Git Bash 에 `sshpass` 가 없어 비밀번호 방식이 안 된다.
  깔 수는 있지만(MSYS2 pacman, Cygwin, winget) Git Bash 의 ssh 와 물리는지는 검증되지 않았다.
  키로 가거나 WSL 에서 실행한다.
  `scripts/ssh-run.sh` 는 `sshpass` 가 없으면 `fail` 이 아니라 `unknown` 을 낸다.
  도구가 없는 것을 구현 실패로 보고하면 안 되기 때문이다.

## VPN 이 소스 IP 를 바꿔 놓을 때

접속 대상이 **출발지 IP 로 허용 목록**을 걸어 두면, VPN 이 default 라우트를 잡는 순간
나가는 공인 IP 가 바뀌어 방화벽이 조용히 버린다. 거부 응답이 없어 **타임아웃으로만 보인다.**

실제로 겪은 형태 (2026-08-18):

```
ssh: connect to host <점프호스트> port 10022: Connection timed out
```

장비는 멀쩡했다. 대상이 회사 공인 IP 에서 온 접속만 받는데, VPN 이 default 를 잡아
개인 회선 IP 로 나가고 있었던 것이다. **같은 머신의 물리 NIC 으로 나가면 이미 회사 IP** 였는데
그걸 못 보고 다른 서버를 경유하는 우회로를 찾느라 시간을 썼다.

### 판정

```sh
ip route get <대상IP>                      # 어느 인터페이스로 나가는가
ip -d link show wg0 | sed -n 3p            # -> wireguard   (kind 로 판정. 이름 규칙은 못 믿는다)
ip -4 route show default                   # 터널 밖 default 후보
```

Windows(Git Bash)에는 `ip` 가 없다. `ssh-run.sh` 의 `win_diag()` 가 PowerShell 로 대신 본다.

```sh
Find-NetRoute -RemoteIPAddress <대상IP>              # 어느 인터페이스로 나가는가
Get-NetAdapter -InterfaceIndex <ifIndex>            # InterfaceType(IANA) 과 드라이버 설명
Get-NetRoute -DestinationPrefix 0.0.0.0/0           # default 후보
curl -s --interface <iface> https://ifconfig.me   # 그 경로로 나갈 때의 공인 IP
```

터널 kind: `wireguard` `tun` `ppp` `ipip` `ip6tnl` `gre` `gretap` `vti` `sit` `xfrm`.
**이름(`wg*`/`tun*`)으로 거르지 않는다** - VPN 클라이언트마다 다르다.

후보는 **`ip -4 route show default` 목록에서만** 뽑는다. `oif` 강제 조회는 필터가 못 된다:

```sh
$ ip route get 203.0.113.1 oif docker0   -> dev docker0 src <docker0 주소>   # 아무 장치나 답을 준다
```

### 우회

```sh
ssh -o BindInterface=<iface> ...    # SO_BINDTODEVICE. 라우팅 테이블을 무시하고 그 장치로 내보낸다
```

`ssh -b <주소>`(BindAddress)로는 **안 된다.** 소스 주소만 바뀌고 경로는 그대로 터널이다:

```sh
$ ip route get 203.0.113.1 from <물리NIC 주소>   -> dev wg0    # 여전히 터널
```

`scripts/ssh-run.sh` 는 `VH_BYPASS=<iface>` 가 있을 때만 **1회** 재시도한다.

- 재시도 조건은 `timed out` / `no route to host` / `network is unreachable` / 자체 timeout 뿐이다.
  **`Connection refused` 와 인증 실패는 제외** - 이미 대상에 도달한 것이라 소스 IP 를 바꿔도 같다.
- 성공하면 JSON 에 `"via":"bypass:<iface>"` 가 찍힌다. 우회로 얻은 pass 를 평범한 pass 로 두지 않는다.
- **값은 사용자 승인을 받아 팀장이 확정해서 넘긴다.** 팀원도 스크립트도 인터페이스를 고르지 않는다.
- 접속 실패로 끝나면 `VH_BYPASS` 유무와 무관하게 **진단이 evidence 에 붙는다.**
  `ip` 가 없는 환경(Windows Git Bash)에서는 조용히 생략된다.

```
[진단] 첫 홉 203.0.113.1 는 wg0(kind=wireguard)로 나감. 터널 밖 default 후보: enp7s0(metric 100). 우회 미시도 (VH_BYPASS 미설정)
```

점프를 쓰면 진단의 첫 홉은 최종 호스트가 아니라 **점프 호스트**다. 로컬에서 나가는 대상이 그것이다.

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

## pgrep 자기 매칭 함정

원격에서 "그 작업이 끝났나" 를 `pgrep` 으로 볼 때 **자기 자신을 매칭해 루프가 영원히 안 끝난다.**

```sh
# 틀림 - ssh 가 실행하는 명령줄에 "mcc infra run" 이 들어 있어 pgrep 이 자기를 찾는다
until timeout 30 ssh -n root@"$H" '! pgrep -f "mcc infra run"'; do sleep 15; done
```

실제로 이 패턴으로 25시간 동안 15초마다 SSH 를 여는 루프가 3개 실행되고 있었다. 기다리던 작업은 이틀 전에 끝나 있었다.

확인:
```sh
$ pgrep -af "mcc infra"
3302987 bash -c ... pgrep -af "mcc infra" ...     # 자기 자신
```

### 고치는 법

```sh
# 1) 대괄호로 자기 매칭을 깬다 (가장 간단)
ssh -n root@"$H" '! pgrep -f "[m]cc infra run"'

# 2) pgrep 대신 종료 표식을 본다 - 더 확실하다
ssh -n root@"$H" 'test -f /tmp/mcc.done'
# 작업 쪽: mcc infra run …; echo $? > /tmp/mcc.done

# 3) pid 를 직접 붙잡는다
PID=$(ssh -n root@"$H" 'pgrep -o -f "[m]cc infra run"')
ssh -n root@"$H" "while kill -0 $PID 2>/dev/null; do sleep 15; done"
```

### 무한 루프 자체를 막는다

**`until` 에는 반드시 횟수 상한을 건다.** 조건이 틀리면 영원히 끝나지 않는다.

```sh
for i in $(seq 1 40); do            # 40 × 15s = 10분 상한
  ssh -n root@"$H" 'test -f /tmp/mcc.done' && break
  [ "$i" = 40 ] && { echo "TIMEOUT - 상태를 직접 확인할 것"; break; }
  sleep 15
done
```

폴링을 시작하기 전에 **기다리는 대상이 실제로 실행 중인지 먼저 확인한다.** 이미 끝났으면 폴링할 이유가 없다.

## 금지

- `timeout` 없는 원격 명령
- 승인 안 된 호스트 접속
- 승인 안 된 재기동·쓰기·삭제
- 비밀번호를 evidence/보고서/**답변 텍스트**에 평문으로 (안 썼다고 설명하는 문장에 값을 붙이는 것도 여기 해당)
- `--since`/`tail` 없는 전체 로그 수집
- 상한 없는 `until` 폴링 (조건이 틀리면 영원히 끝나지 않는다)
- `pgrep -f "<문자열>"` 을 그 문자열이 든 명령 안에서 쓰기 (자기 매칭)
- 승인 없이 `VH_BYPASS` 를 켜거나 인터페이스를 임의로 고르기
- 타임아웃을 보고 "장비가 죽었다" 로 단정하기 (소스 IP 차단이 타임아웃으로 보인다)
