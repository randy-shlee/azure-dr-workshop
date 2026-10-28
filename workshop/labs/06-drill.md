# Lab 06. planned 전환·원복과 사용자 관측

[이전](05-baseline.md) · [목차](../README.md) · [다음](07-cleanup.md)

이 훈련은 KRC 리전 전체를 실제 중단하지 않습니다. backend planned switchover와
KRC TM endpoint Disable로 동작을 확인하는 기능 실습입니다.
**Storage 계정 failover, standalone PG promotion, 강제 데이터 손실 승격은 하지 않습니다.**

## 6-1. 전환 전 게이트

Lab 05 완료 후 지정 오퍼레이터만 실행합니다. 브라우저 탭은 그대로 유지하고
UTC 기록을 시작합니다. `DRILL_LOG`는 기본 `$STATE_DIR/drill-log-YYYYMMDD.csv`입니다.
화면 로그는 해당 탭의 최근 20건이므로 관측 후 필요한 시각을 즉시 기록하세요.

```bash
bash scripts/drill/00-precheck.sh
bash scripts/drill/05-fast-settings.sh
```

실제 파일명은 **05-fast-settings.sh / 99-restore.sh**입니다.
사용자 시나리오의 05-fast-probe/99-restore-probe 명칭과 혼동하지 마세요.
fast 프로브는 10초/실패 1회/timeout 5초/TTL 0이며 추가 과금이 있습니다.
TTL 0은 recursive DNS 캐시/브라우저 연결을 강제로 비우지 않습니다.

## 6-2. KRS planned 전환

```bash
unset CONFIRM
bash scripts/drill/10-failover.sh
```

`FAILOVER <prefix>`를 확인하고 승인합니다. full에서 실행 순서는:

1. EH KRS planned promotion(geo를 활성화했을 때)
2. PG KRS planned switchover
3. KRS TM endpoint Enabled, KRC Disabled
4. DNS KRS IP 대기, 전역 health 확인

lite에서는 EH 단계가 제외됩니다. Storage/Redis/Search의 의미:

- Storage는 KRC primary를 유지하고 KRS 앱은 secondary 기본 읽기입니다.
- Redis는 active geo라 별도 primary promotion 단계가 없습니다.
- Search는 독립된 KRS 인덱스를 사용하며 자동 geo 복제를 가정하지 않습니다.

다음 관측 UTC를 따로 적습니다.

| 관측 | 기록할 값 |
|---|---|
| CSV pg-to-krs/eh-to-krs END | 관리 명령 단계 완료 시각 |
| TM 안내 리전 KRC → KRS | Pod resolver가 KRS를 관측한 시각 |
| 응답 리전 KRC → KRS | 브라우저 요청이 KRS 앱에 응답받은 시각 |
| KRS에서 최초 성공한 쓰기 | UUID/UTC와 서비스별 결과 |

둘의 차이는 DNS 캐시만의 정밀 측정값이 아닙니다. 10초 polling, Pod resolver,
브라우저 캐시, 기존 HTTP 연결, 표본 시각이 함께 반영됩니다.
노란 불일치 안내가 나오면 먼저 시각을 보존한 뒤 필요 시 새/시크릿 창으로 확인합니다.

## 6-3. KRS에서 확인

```bash
curl --fail --silent --show-error "http://$(cfg '.secondary.publicIp.fqdn')/api/info" | jq .
az postgres flexible-server show -g "$(cfg '.secondaryResourceGroup')" \
  -n "$(cfg '.secondary.pg.name')" --query '{state:state,role:replicationRole}' -o json
if enabled '.features.deployEventHubs' && enabled '.features.enableEventHubsGeoReplication'; then
  bash scripts/eh-georeplication.sh status
fi
```

브라우저에서 쓰기/읽기/샘플 버튼을 눌러 다음을 확인합니다.

- 응답 KRS, TM KRS, Storage 읽기 secondary
- Storage secondary 카드 PE=KRS 및 샘플 secondary 실제 읽기
- PG/EH는 KRS로 planned 전환된 역할에서 성공
- Blob 쓰기는 primary endpoint이며 KRC Storage 계정에 계속 기록
- Search/Redis는 KRS 인스턴스의 실제 결과. PG/EH와 같은 전환 방식이 아님

KRC endpoint가 Disabled인 동안 `00-precheck.sh`/`test-app.sh`의 평시 게이트가
통과한다고 가정하지 않습니다. 특히 precheck는 두 endpoint Enabled/Online을 요구하므로
이 상태에서 실패가 정상일 수 있습니다. 위 역할 조회와 화면을 사용하세요.

## 6-4. 안전한 원복

```bash
bash scripts/drill/20-failback.sh
bash scripts/drill/99-restore.sh
bash scripts/drill/00-precheck.sh
```

`FAILBACK <prefix>` 승인 후 PG/EH backend를 **먼저 KRC로** 돌리고,
우선순위 높은 KRC endpoint를 Enabled로 바꿉니다. backend 준비 전 KRC 트래픽을
복귀시키지 않는 안전 순서입니다. KRS는 priority 2 standby로 Enabled를 유지합니다.
99는 프로브를 30초/3회/timeout 10초/TTL 60으로 돌릴 뿐 backend 역할을 원복하지 않습니다.

두 배지 KRC와 쓰기/읽기 재확인 후 프로브 설정을 조회합니다.

```bash
az network traffic-manager profile show --ids "$(cfg '.trafficManager.id')" \
  --query '{ttl:dnsConfig.ttl,monitor:monitorConfig,endpoints:endpoints[].{name:name,status:endpointStatus,monitor:endpointMonitorStatus}}' -o json
```

## 실패/부분 성공 시

즉시 자동으로 반대 스크립트를 실행하지 않습니다. csv ERROR 단계, PG 실제 role,
EH 실제 primary/replica 상태, TM endpoint 상태를 강사와 확인합니다.
Bicep 재배포로 초기 역할을 덮어쓰거나 standalone 승격하지 않습니다.
긴 대기는 DNS/EH timeout과 실제 복제 상태를 확인한 뒤 조정합니다.
훈련 중단 시에도 가능한 범위에서 99로 빠른 프로브를 복구하되, 이것을 원복 완료로
기록하지 않습니다. 미완료 역할과 과금 책임자를 명시합니다.

## 완료 게이트

- [ ] full은 EH/PG planned 전환, lite는 제외 범위 기록
- [ ] TM/응답 리전 변화를 별개 UTC로 기록, KRS 실제 데이터 작업 성공
- [ ] KRC backend/두 배지 복귀와 쓰기/읽기 재확인
- [ ] 기본 프로브/TTL 복구, 양 endpoint Online
- [ ] 화면 이벤트와 drill CSV 비교. RTO/RPO 보장값으로 과장하지 않음
