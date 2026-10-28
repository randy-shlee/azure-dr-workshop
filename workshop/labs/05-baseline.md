# Lab 05. 평시 브라우저/API 기능 검증

[이전](04-application.md) · [목차](../README.md) · [다음](06-drill.md)

## 5-1. 주소와 평시 역할 확인

```bash
TM_FQDN="$(cfg '.trafficManager.fqdn')"
printf 'TM:  http://%s/\nKRC: http://%s/\nKRS: http://%s/\n' \
  "$TM_FQDN" "$(cfg '.primary.publicIp.fqdn')" "$(cfg '.secondary.publicIp.fqdn')"
nslookup "$TM_FQDN"
curl --fail --silent --show-error "http://$TM_FQDN/healthz" | jq .
curl --fail --silent --show-error "http://$TM_FQDN/api/info" | jq .
bash scripts/drill/00-precheck.sh
```

health는 의존 서비스를 호출하지 않으며 `status=ok`, 평시 region=krc입니다.
precheck는 AKS/PG 상태, 사용 가능한 복제 metric, EH geo 상태, Storage Last Sync Time,
양쪽 리전/전역 앱 진입점, TM 두 endpoint와 DNS를 확인합니다.
metric 샘플이 없으면 지연 0이라고 해석하지 않습니다.

브라우저에서 TM 주소를 열고 자동 갱신을 켭니다. 기대값:

| 항목 | 평시 기대값 |
|---|---|
| 응답한 서버 리전 / TM 안내 리전 | KRC / KRC |
| Pod/Host/Storage 읽기 모드 | 실제 값 / TM FQDN / primary |
| 활성 서비스 카드 | 정상, FQDN/IP/응답 시간 표시 |
| lite 선택 서비스 | disabled; 오류를 숨긴 성공 표시가 아님 |
| Storage secondary PE | KRC 화면에서도 KRS PE(10.20.*)를 global peering으로 조회 가능 |

Search/Redis의 지역별 구성과 데이터는 같다고 가정하지 않습니다.
평시부터 backend 역할이 이미 KRS이면 강사와 토폴로지를 복구하고 시작합니다.

## 5-2. 쓰기 → 읽기 → 데이터 의미 확인

1. **쓰기 테스트**: UUID/UTC 시각을 기록하고 활성 PG/Redis/EH/Blob/Search 결과를 확인합니다.
2. **읽기 테스트**: PG 최신 행, Redis `dr:last`, Blob 최신 JSON, Search 문서 수,
   EH 파티션별 마지막 sequence number를 확인합니다.
3. 서로 다른 서비스의 반환 항목이 왜 다른지 설명합니다. EH sequence number는
   메시지 본문을 소비/대조했다는 증거가 아니며 Search count는 비동기 반영될 수 있습니다.
4. 쓰기는 분산 트랜잭션이 아닙니다. partial/error와 서비스별 결과를 확인하고
   Event Hubs 재시도 중복 가능성은 UUID로 구별합니다.
5. 실패 원인을 확인하지 않고 반복 클릭해 데이터를 많이 생성하지 않습니다.

테스트 표의 Blob `read_only:true`는 primary 쓰기 실패 신호이며, 앱 프로세스
전체가 죽었다는 뜻이 아닙니다. Storage 계정이 실제로 secondary로 승격되었다는 뜻도 아닙니다.

## 5-3. 샘플 버튼은 수동으로만

**샘플 데이터 확인**을 누릅니다. 양쪽 manifest 종료 시각, 파일 수/용량, 1MiB
읽기 시간, Last Sync Time, 복제 완료 여부를 기록합니다.
10GiB 프로필의 기대 파일 수는 large 8, small 2,000이고 실제 용량은 약 9.953GiB입니다.
활성 설정이 다르면 배포 outputs의 값을 기준으로 합니다.

목록은 endpoint별 300초 캐시됩니다. 데이터가 바뀐 직후 수치가 같지 않으면
5분 뒤 다시 조회하고, null/pending/error를 완료로 적지 않습니다.
실제 1MiB range 읽기 결과와 manifest/집계 상태도 함께 봅니다.

## 5-4. Pod에서 Storage secondary 사설 해석

```bash
ACCOUNT="$(cfg '.primary.storage.name')"
aks_run secondary \
  "kubectl -n drtest exec deployment/drtest-app -- python -c \"import socket; print(socket.gethostbyname('${ACCOUNT}-secondary.blob.core.windows.net'))\""
```

기대는 10.20.*입니다. `pe_region`은 **PE IP 대역**이지 PG/EH 현재 primary 또는
Storage 데이터의 실제 리전 판정이 아닙니다. PG/EH 역할은 precheck/ARM과 함께 봅니다.

## 5-5. 전체 CLI smoke

```bash
bash scripts/test-app.sh
```

이 명령은 실제로 쓰기 요청을 한 번 보냅니다. nslookup/IP 판정, info/tm,
write/read/sampledata와 두 Pod 내부 check의 PE 표를 확인합니다.
의존 서비스 오류나 partial이 있으면 nonzero입니다. 장애를 유도하는 명령은 없습니다.

## 완료 게이트

- [ ] 두 배지 KRC, 두 endpoint Online, 역할/복제 precheck 확인
- [ ] 활성 서비스 쓰기/읽기 성공과 UUID/UTC 기록
- [ ] 양쪽 샘플 수·용량·보조 읽기·복제 완료 확인
- [ ] Pod-side PE와 관리 평면 primary 리전의 의미 구별
- [ ] 관측 CSV/스크린샷에 비밀 없이 평시 증거 보관
