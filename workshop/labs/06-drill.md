# Lab 06. 승인된 planned 전환·원복·관측

[이전](05-baseline.md) · [목차](../README.md) · [다음: 종료](07-cleanup.md)

## 6-0. 실행 경계

**배포/앱/10 GB/복제 실증은 완료, 실제 failover/failback은 아직 미실행**입니다.
이 문서는 [실제 스크립트](../../scripts/drill/10-failover.sh)에 맞춘 승인 실습 절차입니다.
리전 전체 장애 주입, unplanned Storage 승격, PG standalone promotion,
EH 이전 primary failback, 99:1, SLA/RTO/RPO 인증은 제외합니다.

지정 오퍼레이터 한 명만 해당 팀 source/config로 실행합니다.
전환 시각·이미 성공한 단계·실패를 `$STATE_DIR/drill-log-YYYYMMDD.csv`와 관측 CSV에 남깁니다.
Storage 각 planned 작업은 수 시간도 걸릴 수 있습니다. 중복/반대 명령으로 재촉하지 않습니다.

## 6-1. 첫 전환 전 게이트

[Lab 02](02-data.md)/[Lab 04](04-application.md)/[Lab 05](05-baseline.md)를 통과합니다.
특히 최종 manifest fence와 실제 읽기, EH 원래 이벤트 보존/consumer restart·replay 계획을 확인합니다.

```bash
bash scripts/drill/00-precheck.sh
```

실패하면 진행하지 않습니다. 현재 full의 첫 baseline:
Storage 단일 RA-GRS/KRC primary/KRS secondary/Live/Planned 가능,
PG KRC Ready Primary·KRS Ready replica, writer/reader aliases, EH KRC synchronized pairing,
양 TM Enabled/Online입니다. PG GeneralPurpose 로컬 Premium_LRS는 정상입니다.

기본 프로브 30초/3회/timeout 10초·TTL 60을 유지합니다.
`05-fast-settings.sh`는 기본 과정에서 제외하며 별도 승인 시에만 사용합니다.
추가 과금과 TTL 0의 캐시 purge 불가를 설명하고 99번으로 복구합니다.

## 6-2. KRS planned 전환

```bash
unset CONFIRM
bash scripts/drill/10-failover.sh
```

`FAILOVER <prefix>` 승인 후 **실제 코드 순서**:

| 순서 | 작업 / gate |
|---|---|
| 1 | Storage `storage_planned_failover secondary`, 동기 완료 후 RA-GRS/실제 KRS primary 확인 |
| 2 | EH `failover krs`, metadata-only alias가 KRS active 상태인지 확인 |
| 3 | PG KRS planned switchover, Ready primary/역방향 replica 확인 |
| 4 | KRS TM Enable → KRC Disable → DNS KRS IP → global health |
| 5 | `dr_verify_data secondary`: 응답 KRS/primary 읽기 모드, Blob/PG 동일 UUID 읽기, EH send/metadata |

일부 문서의 옛 **Storage → PG → EH** 설명과 달리 현재 스크립트는 **Storage → EH → PG**입니다.
문서에 맞추려고 런타임 순서를 임의 변경하지 않습니다.
Storage CLI는 `--failover-type Planned`를 사용하고 `--no-wait` 없이 완료를 기다립니다.
PG는 `--promote-mode switchover --promote-option planned`로 복제/alias를 자동 역전합니다.
건강한 planned 원복에 replica 삭제/수동 재구축은 필요 없습니다.

## 6-3. KRS에서 관리 역할과 데이터 확인

```bash
storage_account | jq '{sku:.sku.name,primaryLocation,secondaryLocation,failoverInProgress,geoReplicationStats}'
storage_assert_region secondary "$(storage_account)"
pg_assert_pair secondary
bash scripts/eh-georecovery.sh status
bash scripts/eh-georecovery.sh wait krs
az network traffic-manager profile show --ids "$(cfg '.trafficManager.id')" \
  --query '{endpoints:endpoints[].{name:name,status:endpointStatus,monitor:endpointMonitorStatus}}' -o json
dr_verify_data secondary
```

관리 결과와 화면을 대조합니다.

- KRS/KRS, Storage primary KRS, PG writer KRS, EH alias KRS `PrimaryNotReplicating`.
- Blob 일반 작업은 같은 **primary hostname**. 이전 이벤트는 KRC EH에 남습니다.
- `dr_verify_data`는 Redis/Search 전체를 hard gate로 검사하지 않으므로 **모든 서비스 실제 결과도 별도 확인**합니다.
- Search 독립 인덱스의 기존 문서가 이동했다고 판단하지 않습니다.
- EH send/metadata 성공은 이전 이벤트 소비/replay/offset 정합성 성공이 아닙니다.

full의 전체 서비스 결과를 확인하는 경우:

```bash
curl --fail --silent --show-error --max-time 40 -X POST \
  "http://$(cfg '.trafficManager.fqdn')/api/write" >"$STATE_DIR/krs-write.json"
jq -e '.status == "ok" and all(.services[]; .ok == true)' "$STATE_DIR/krs-write.json"
curl --fail --silent --show-error --max-time 40 \
  "http://$(cfg '.trafficManager.fqdn')/api/read" | jq .
```

위 JSON은 레코드/상태만 기록하며 Secret을 포함하지 않습니다. 공유 전 내용을 확인합니다.
이 동안 다른 사용자가 쓰지 않도록 조율합니다.
KRC Disabled 중에는 양쪽 Enabled를 전제하는 `00-precheck.sh`/평시 `test-app.sh`를 쓰지 않습니다.
`-secondary` 샘플 probe도 전환 후 DR 판정에 쓰지 않습니다.

## 6-4. KRC 앱 원복

```bash
unset CONFIRM
bash scripts/drill/20-failback.sh
bash scripts/drill/99-restore.sh
storage_assert_region primary "$(storage_account)"
pg_assert_pair primary
bash scripts/eh-georecovery.sh wait active
bash scripts/eh-georecovery.sh status
tm_assert_online
dr_verify_data primary
```

`FAILBACK <prefix>` 승인 후 순서는 **Storage KRC → PG KRC → EH active 확인 → TM KRC**입니다.
KRS endpoint도 priority 2로 Enabled를 유지합니다.
Blob/PG 동일 ID, EH 접근과 Redis/Search의 실제 결과를 다시 확인합니다.
`99-restore.sh`는 프로브/TTL만 복구하고 데이터 역할은 바꾸지 않습니다.

**EH alias는 KRS에 남습니다.** `wait active`는 정상 초기 KRC pair 또는 fail-forward한
KRS를 허용하므로 부분 drill 복구에도 쓸 수 있지만 모든 역할 원복의 증명은 아닙니다.
이전 KRC로 EH failback/기존 데이터 삭제/자동 re-pair는 금지합니다.
다음 보호는 새 EMPTY namespace와 별도 승인이 필요합니다.
첫 baseline `wait krc`/`00-precheck.sh`는 원복 후 다시 요구하지 않습니다.

## 6-5. 관측과 중단

Storage/EH/PG 각 END, TM 안내 변화, 응답 리전 변화, 최초 데이터 성공을 별도 UTC로 기록합니다.
DNS/브라우저 캐시, 기존 연결, 10초 polling이 함께 반영되므로 차이를 DNS 캐시만의 정밀 지연으로 보지 않습니다.
브라우저 로그는 같은 탭의 최근 20건입니다. 필요한 시각은 CSV에 저장합니다.

부분 실패 시 CSV ERROR, Storage/PG/EH 실제 역할, TM 상태와 데이터 결과부터 확인합니다.
반대 명령/새 Bicep/standalone 승격을 무조건 실행하지 않습니다.
TM endpoint만 Disable/Enable하는 체험은 DNS 경로 확인이지 전체 backend DR가 아닙니다.

## 완료 게이트

- [ ] 실행/미실행/부분 실행 구별, 역할·동일 UUID·UTC 보관
- [ ] Storage/PG·앱 KRC, EH KRS 유지와 실제 접근 확인
- [ ] Redis/Search 결과, 양 TM Online, 기본 프로브/TTL, 보관/삭제 책임 인계
