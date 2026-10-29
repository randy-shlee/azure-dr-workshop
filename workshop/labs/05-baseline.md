# Lab 05. 평시 데이터와 첫 DR baseline

[이전](04-application.md) · [목차](../README.md) · [다음: 승인 DR](06-drill.md)

## 5-1. 주소·앱 생존·실제 역할

[실제 config 환경](01-infrastructure.md#새-터미널에서-복원)에서 실행합니다.

```bash
TM_FQDN="$(cfg '.trafficManager.fqdn')"
printf 'TM: http://%s/\nKRC: http://%s/\nKRS: http://%s/\n' \
  "$TM_FQDN" "$(cfg '.primary.publicIp.fqdn')" "$(cfg '.secondary.publicIp.fqdn')"
curl --fail --silent --show-error --max-time 40 "http://$TM_FQDN/healthz" | jq .
curl --fail --silent --show-error --max-time 40 "http://$TM_FQDN/api/info" | jq .
bash scripts/drill/00-precheck.sh
```

`/healthz`는 의존 서비스를 호출하지 않는 liveness입니다.
precheck는 AKS/PG 역할·접근, Storage RA-GRS/Live/Planned 지원,
첫 EH KRC synchronized pairing, TM 양 Online·DNS/health 등을 확인합니다.
샘플 exact byte/읽기나 모든 데이터 의미까지 대신 확인하는 명령은 아닙니다.
사용 가능한 metric에 샘플이 없으면 lag 0으로 해석하지 않습니다. EH payload lag metric은 없습니다.

PG pair 조회와 별도로 실제 config의 writer/reader aliases와 앱 PG_HOST를 확인합니다.
양 앱의 일반 연결은 **writer alias**이며 KRS를 reader로 자동 분기하는 앱이 아닙니다.
Storage/PG primary와 PE 위치/응답 리전을 구별합니다.

## 5-2. 쓰기 → 읽기

TM 탭에서 자동 갱신을 켜고 KRC/KRC를 확인한 후:

1. 쓰기 한 번: UUID/UTC와 모든 활성 서비스 결과.
2. 읽기 한 번: Blob/PG 동일 UUID, Redis 결과, Search count, EH sequence metadata.
3. full의 partial/error는 전체 성공 아님. 쓰기는 분산 트랜잭션이 아니며 재시도 중복 가능.
4. 정확한 ID 비교 중 다른 사용자/프로브의 동시 쓰기를 피합니다.

API로도 같은 흐름을 볼 수 있습니다.

```bash
curl --fail --silent --show-error --max-time 40 -X POST "http://$TM_FQDN/api/write" | jq .
curl --fail --silent --show-error --max-time 40 "http://$TM_FQDN/api/read" | jq .
bash scripts/test-app.sh
```

`test-app.sh`는 실제 쓰기를 만들고 양 Pod 체크까지 수행하는 **평시 smoke**입니다.
복제 flag를 최종 gate로 강제하는 명령은 아니므로 [Lab 02](02-data.md)를 별도로 통과해야 합니다.
UI의 Search count/EH sequence는 정확한 Search 문서/이벤트 본문 대조가 아닙니다.
v1.0.7 보고서의 별도 payload 소비 성공을 이번 UI 동작으로 재현했다고 기록하지 않습니다.

## 5-3. 첫 전환 전 사설 보조 읽기

```bash
ACCOUNT="$(cfg '.primary.storage.name')"
aks_run secondary \
  "kubectl -n drtest exec deployment/drtest-app -- python -c \"import socket; print(socket.gethostbyname('${ACCOUNT}-secondary.blob.core.windows.net'))\""
```

현재 KRS PE는 10.20.*입니다. 실제 1 MiB 읽기·전체 inventory·manifest fence는
양 지역 앱 샘플 화면/API에서 확인합니다. DNS/목록만 성공한 것은 읽기 성공이 아닙니다.
`-secondary`는 **첫 전환 전 probe**이며 다음 Lab의 전환 후 일반 읽기에 쓰지 않습니다.

## 완료 게이트

- [ ] KRC/KRC, 양 Online·역할/안정 alias 확인
- [ ] 모든 활성 서비스 실제 쓰기/읽기와 UUID/UTC
- [ ] 양 샘플 exact 10 GB·읽기·최종 fence
- [ ] 첫 EH 페어링인지 확인. 이미 fail-forward한 환경은 첫 baseline 재실행 금지
